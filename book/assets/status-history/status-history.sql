-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f status-history.sql in an empty database.
-- Expected errors are checked by SQLSTATE; all lab objects roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA workflow_example;
REVOKE ALL ON SCHEMA workflow_example FROM PUBLIC;

CREATE TABLE workflow_example.order_status (
    code text PRIMARY KEY
);
CREATE TABLE workflow_example.status_transition (
    from_status text REFERENCES workflow_example.order_status (code),
    to_status text REFERENCES workflow_example.order_status (code),
    PRIMARY KEY (from_status, to_status),
    CHECK (from_status <> to_status)
);
CREATE TABLE workflow_example.sales_order (
    order_id bigint PRIMARY KEY,
    status_code text NOT NULL DEFAULT 'draft'
        REFERENCES workflow_example.order_status (code),
    revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE workflow_example.order_status_history (
    order_id bigint REFERENCES workflow_example.sales_order (order_id),
    revision bigint CHECK (revision > 0),
    from_status text NOT NULL,
    to_status text NOT NULL,
    changed_at timestamptz NOT NULL,
    actor text NOT NULL CHECK (btrim(actor) <> ''),
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    PRIMARY KEY (order_id, revision),
    CONSTRAINT history_transition_fk FOREIGN KEY (from_status, to_status)
        REFERENCES workflow_example.status_transition (from_status, to_status)
);

CREATE FUNCTION workflow_example.move_order(
    p_order_id bigint, p_expected_revision bigint, p_to_status text,
    p_actor text, p_reason text
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    current_order workflow_example.sales_order%ROWTYPE;
    next_revision bigint;
BEGIN
    SELECT * INTO STRICT current_order
    FROM workflow_example.sales_order
    WHERE order_id = p_order_id FOR UPDATE;
    IF current_order.revision IS DISTINCT FROM p_expected_revision THEN
        RAISE EXCEPTION 'stale order revision: expected %, found %',
            p_expected_revision, current_order.revision USING ERRCODE = 'P0001';
    END IF;
    next_revision := current_order.revision + 1;
    INSERT INTO workflow_example.order_status_history
        (order_id, revision, from_status, to_status, changed_at, actor, reason)
    VALUES (p_order_id, next_revision, current_order.status_code,
            p_to_status, clock_timestamp(), p_actor, p_reason);
    UPDATE workflow_example.sales_order
    SET status_code = p_to_status, revision = next_revision
    WHERE order_id = p_order_id;
    RETURN next_revision;
END;
$$;
REVOKE ALL ON FUNCTION workflow_example.move_order(bigint, bigint, text, text, text)
    FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA workflow_example FROM PUBLIC;

INSERT INTO workflow_example.order_status VALUES
    ('draft'), ('paid'), ('shipped'), ('cancelled');
INSERT INTO workflow_example.status_transition VALUES
    ('draft', 'paid'), ('draft', 'cancelled'),
    ('paid', 'shipped'), ('paid', 'cancelled');
INSERT INTO workflow_example.sales_order (order_id) VALUES (1001);

SELECT workflow_example.move_order(1001, 0, 'paid', 'user:42', 'Payment captured');
SELECT workflow_example.move_order(1001, 1, 'shipped', 'user:81', 'Carrier pickup');
SELECT order_id, status_code, revision FROM workflow_example.sales_order;
SELECT revision, from_status, to_status, actor, reason
FROM workflow_example.order_status_history
WHERE order_id = 1001 ORDER BY revision;
-- Current: (1001, shipped, 2); history: draft -> paid, paid -> shipped.

SAVEPOINT forbidden_transition;
\set ON_ERROR_STOP off
SELECT workflow_example.move_order(1001, 2, 'draft', 'user:42', 'Reopen order');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT forbidden_transition;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

SAVEPOINT stale_revision;
\set ON_ERROR_STOP off
SELECT workflow_example.move_order(1001, 1, 'cancelled', 'user:42', 'Stale request');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT stale_revision;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

-- Owner-only counterexample: the pair FK cannot verify the current state.
-- This succeeds despite the order being shipped. Roll it back immediately.
SAVEPOINT bypass_writer;
INSERT INTO workflow_example.order_status_history
    (order_id, revision, from_status, to_status, changed_at, actor, reason)
VALUES (1001, 3, 'draft', 'cancelled', clock_timestamp(), 'owner', 'FK counterexample');
ROLLBACK TO SAVEPOINT bypass_writer;

-- A failed current-row update must also roll back the preceding history insert.
SAVEPOINT atomic_failure;
INSERT INTO workflow_example.sales_order (order_id) VALUES (1002);
CREATE FUNCTION workflow_example.reject_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'simulated current-row failure' USING ERRCODE = 'P0001';
END;
$$;
CREATE TRIGGER simulated_failure BEFORE UPDATE ON workflow_example.sales_order
FOR EACH ROW EXECUTE FUNCTION workflow_example.reject_update();
SAVEPOINT failed_call;
\set ON_ERROR_STOP off
SELECT workflow_example.move_order(1002, 0, 'paid', 'user:42', 'Failure test');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT failed_call;
SELECT :'rejected_state' = 'P0001'
    AND (SELECT count(*) = 2 FROM workflow_example.order_status_history)
    AND (SELECT status_code = 'draft' AND revision = 0
         FROM workflow_example.sales_order WHERE order_id = 1002)
    AND (SELECT status_code = 'shipped' AND revision = 2
         FROM workflow_example.sales_order WHERE order_id = 1001) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
ROLLBACK TO SAVEPOINT atomic_failure;
ROLLBACK;
