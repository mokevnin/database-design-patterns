-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f transactional-outbox.sql in a disposable database.
-- Expected errors are isolated and their SQLSTATEs checked; all other errors stop execution.
\set ON_ERROR_STOP on
CREATE SCHEMA transactional_outbox_lab;
SET search_path = transactional_outbox_lab, public;

CREATE TABLE sales_order (
    order_id bigint PRIMARY KEY,
    state text NOT NULL CHECK (state IN ('pending', 'paid', 'cancelled')),
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0)
);
CREATE TABLE outbox_event (
    event_id uuid PRIMARY KEY DEFAULT uuidv4(),
    order_id bigint NOT NULL REFERENCES sales_order (order_id),
    revision bigint NOT NULL CHECK (revision > 0),
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    published_at timestamptz,
    CONSTRAINT outbox_order_revision_key UNIQUE (order_id, revision)
);
CREATE INDEX outbox_pending_idx ON outbox_event (order_id, revision)
WHERE published_at IS NULL;
INSERT INTO sales_order VALUES (1, 'pending', 0);
BEGIN;
WITH changed AS (
    UPDATE sales_order SET state = 'paid', revision = revision + 1
    WHERE order_id = 1 AND state = 'pending' AND revision = 0
    RETURNING order_id, revision, state
)
INSERT INTO outbox_event (event_id, order_id, revision, event_type, payload)
SELECT '00000000-0000-4000-8000-000000000001', order_id, revision, 'OrderPaid',
       jsonb_build_object('schema_version', 1, 'order_id', order_id,
                          'revision', revision, 'state', state)
FROM changed
RETURNING event_id, revision;
COMMIT;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
-- Expected SQLSTATE 23505.
INSERT INTO outbox_event (event_id, order_id, revision, event_type, payload)
VALUES ('00000000-0000-4000-8000-000000000002', 1, 1, 'OrderPaid', '{}');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

BEGIN;
SELECT o.order_id FROM sales_order AS o
WHERE EXISTS (
    SELECT 1 FROM outbox_event AS e
    WHERE e.order_id = o.order_id AND e.published_at IS NULL
)
ORDER BY o.order_id LIMIT 1
FOR UPDATE OF o SKIP LOCKED;
SELECT event_id, event_type, payload FROM outbox_event
WHERE order_id = 1 AND published_at IS NULL
ORDER BY revision LIMIT 1 FOR UPDATE;
-- Publish this exact event; wait for the broker acknowledgement.
-- The SQL-only lab assumes that acknowledgement succeeds here.
UPDATE outbox_event SET published_at = clock_timestamp()
WHERE event_id = '00000000-0000-4000-8000-000000000001'
  AND published_at IS NULL
RETURNING event_id;
COMMIT;


DO $$ BEGIN
    IF (SELECT state FROM sales_order WHERE order_id = 1) <> 'paid'
       OR (SELECT count(*) FROM outbox_event WHERE published_at IS NOT NULL) <> 1 THEN
        RAISE EXCEPTION 'production or marking failed';
    END IF;
END $$;
-- A failed/rolled-back producer leaves neither a new revision nor event.
BEGIN;
WITH changed AS (
    UPDATE sales_order SET state = 'cancelled', revision = revision + 1
    WHERE order_id = 1 RETURNING order_id, revision, state
)
INSERT INTO outbox_event (order_id, revision, event_type, payload)
SELECT order_id, revision, 'OrderCancelled', jsonb_build_object('state',state)
FROM changed;
ROLLBACK;
DO $$ BEGIN
    IF (SELECT revision FROM sales_order WHERE order_id = 1) <> 1
       OR (SELECT count(*) FROM outbox_event) <> 1 THEN
        RAISE EXCEPTION 'producer rollback left a partial change';
    END IF;
END $$;

RESET search_path;
DROP SCHEMA transactional_outbox_lab CASCADE;
