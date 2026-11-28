-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f archive-table.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
-- A second session is simulated by running its statements in order.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA archive_example;

-- Live tables: an order aggregate (order plus lines) and a refund outside it.
CREATE TABLE archive_example.customer (
    customer_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE archive_example.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES archive_example.customer (customer_id),
    status text NOT NULL CHECK (status IN ('open', 'closed')),
    closed_at timestamptz,
    CHECK ((status = 'closed') = (closed_at IS NOT NULL))
);
CREATE INDEX orders_closed_at_idx ON archive_example.orders (closed_at)
    WHERE status = 'closed';
CREATE TABLE archive_example.order_line (
    order_id bigint NOT NULL REFERENCES archive_example.orders (order_id),
    line_no integer NOT NULL,
    sku text NOT NULL,
    amount numeric(12, 2) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);
CREATE TABLE archive_example.refund (
    refund_id bigint PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES archive_example.orders (order_id),
    amount numeric(12, 2) NOT NULL
);

-- Archive tables: same keys, typed columns, only closed orders.
CREATE TABLE archive_example.order_archive (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES archive_example.customer (customer_id),
    status text NOT NULL,
    closed_at timestamptz,
    archived_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT order_archive_closed CHECK (status = 'closed' AND closed_at IS NOT NULL)
);
CREATE TABLE archive_example.order_line_archive (
    order_id bigint NOT NULL REFERENCES archive_example.order_archive (order_id),
    line_no integer NOT NULL,
    sku text NOT NULL,
    amount numeric(12, 2) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);

-- One batch: pick closed old orders nobody live refers to, move them with their lines.
CREATE FUNCTION archive_example.archive_closed_orders(cutoff timestamptz, batch_size integer)
RETURNS bigint
LANGUAGE sql
AS $$
WITH picked AS (
    SELECT o.order_id
    FROM archive_example.orders AS o
    WHERE o.status = 'closed'
      AND o.closed_at < cutoff
      AND NOT EXISTS (SELECT FROM archive_example.refund AS r WHERE r.order_id = o.order_id)
    ORDER BY o.closed_at, o.order_id
    LIMIT batch_size
    FOR UPDATE SKIP LOCKED
), moved_lines AS (
    DELETE FROM archive_example.order_line AS l
    USING picked AS p
    WHERE l.order_id = p.order_id
    RETURNING l.*
), moved_orders AS (
    DELETE FROM archive_example.orders AS o
    USING picked AS p
    WHERE o.order_id = p.order_id
    RETURNING o.*
), archived_orders AS (
    INSERT INTO archive_example.order_archive (order_id, customer_id, status, closed_at)
    SELECT order_id, customer_id, status, closed_at FROM moved_orders
    RETURNING order_id
), archived_lines AS (
    INSERT INTO archive_example.order_line_archive (order_id, line_no, sku, amount)
    SELECT order_id, line_no, sku, amount FROM moved_lines
)
SELECT count(*) FROM archived_orders;
$$;

-- Plans as text, to check which tables a query reads.
CREATE FUNCTION archive_example.plan_of(query text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    plan_line text;
    plan_text text := '';
BEGIN
    FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
        plan_text := plan_text || plan_line || E'\n';
    END LOOP;
    RETURN plan_text;
END;
$$;

INSERT INTO archive_example.customer VALUES (1, 'Ada'), (2, 'Ben');
INSERT INTO archive_example.orders VALUES
    (1, 1, 'closed', '2018-03-05 10:00+00'),
    (2, 1, 'closed', '2023-01-10 10:00+00'),
    (3, 2, 'closed', '2023-02-20 10:00+00'),
    (4, 2, 'closed', '2023-04-02 10:00+00'),
    (5, 2, 'closed', '2026-10-01 10:00+00'),
    (6, 2, 'open', NULL);
INSERT INTO archive_example.order_line VALUES
    (1, 1, 'tea', 4.00), (1, 2, 'cup', 9.50),
    (2, 1, 'tea', 4.00), (2, 2, 'pot', 30.00),
    (3, 1, 'cup', 9.50),
    (4, 1, 'pot', 30.00),
    (5, 1, 'tea', 4.00),
    (6, 1, 'tea', 4.00);
-- Order 4 is old and closed, but a live refund still refers to it.
INSERT INTO archive_example.refund VALUES (40, 4, 30.00);

-- Archive orders closed before this instant (two years before 2026-11-27).
\set cutoff '2024-11-27 00:00+00'

-- A move that ignores live references fails as a whole: order 1 stays live too.
\set ids '{1,4}'
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
WITH moved_lines AS (
    DELETE FROM archive_example.order_line
    WHERE order_id = ANY (:'ids'::bigint[]) RETURNING *
), moved_orders AS (
    DELETE FROM archive_example.orders
    WHERE order_id = ANY (:'ids'::bigint[]) RETURNING *
), archived_orders AS (
    INSERT INTO archive_example.order_archive (order_id, customer_id, status, closed_at)
    SELECT order_id, customer_id, status, closed_at FROM moved_orders
)
INSERT INTO archive_example.order_line_archive (order_id, line_no, sku, amount)
SELECT order_id, line_no, sku, amount FROM moved_lines;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503'
   AND (SELECT count(*) FROM archive_example.orders) = 6
   AND (SELECT count(*) FROM archive_example.order_archive) = 0 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The archiver reads candidates, then support reopens order 3 before the move.
SELECT array_agg(order_id ORDER BY order_id) AS stale_ids
FROM archive_example.orders AS o
WHERE status = 'closed' AND closed_at < :'cutoff'
  AND NOT EXISTS (SELECT FROM archive_example.refund AS r WHERE r.order_id = o.order_id) \gset
SELECT :'stale_ids' = '{1,2,3}' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
UPDATE archive_example.orders SET status = 'open', closed_at = NULL WHERE order_id = 3;

-- Moving the stale ID list would archive an open order; the archive's CHECK stops the batch.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
WITH moved_lines AS (
    DELETE FROM archive_example.order_line
    WHERE order_id = ANY (:'stale_ids'::bigint[]) RETURNING *
), moved_orders AS (
    DELETE FROM archive_example.orders
    WHERE order_id = ANY (:'stale_ids'::bigint[]) RETURNING *
), archived_orders AS (
    INSERT INTO archive_example.order_archive (order_id, customer_id, status, closed_at)
    SELECT order_id, customer_id, status, closed_at FROM moved_orders
)
INSERT INTO archive_example.order_line_archive (order_id, line_no, sku, amount)
SELECT order_id, line_no, sku, amount FROM moved_lines;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND (SELECT count(*) FROM archive_example.order_archive) = 0 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The archiver re-evaluates the condition at move time; a batch of 1 moves one whole order.
SELECT archive_example.archive_closed_orders(:'cutoff', 1) AS moved \gset
SELECT :moved = 1
   AND (SELECT array_agg(order_id) FROM archive_example.order_archive) = '{1}'
   AND (SELECT count(*) FROM archive_example.order_line_archive WHERE order_id = 1) = 2
   AND NOT EXISTS (SELECT FROM archive_example.order_line WHERE order_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT archive_example.archive_closed_orders(:'cutoff', 100) = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT archive_example.archive_closed_orders(:'cutoff', 100) AS moved \gset
SELECT :moved = 0
   AND (SELECT array_agg(order_id ORDER BY order_id) FROM archive_example.orders) = '{3,4,5,6}'
   AND (SELECT array_agg(order_id ORDER BY order_id) FROM archive_example.order_archive) = '{1,2}'
   AND (SELECT count(*) FROM archive_example.order_line_archive) = 4 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A live row cannot refer to an archived order.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO archive_example.refund VALUES (41, 2, 4.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Reopening an archived order through the live table changes nothing.
UPDATE archive_example.orders SET status = 'open', closed_at = NULL WHERE order_id = 2;
SELECT :ROW_COUNT = 0 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The archive refers to the live customer, which keeps that customer live.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM archive_example.customer WHERE customer_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Queries that span both tiers read through a UNION ALL view with an archived flag.
CREATE VIEW archive_example.order_all AS
SELECT order_id, customer_id, status, closed_at, false AS archived
FROM archive_example.orders
UNION ALL
SELECT order_id, customer_id, status, closed_at, true AS archived
FROM archive_example.order_archive;

SELECT (SELECT count(*) FROM archive_example.order_all) = 6
   AND (SELECT archived FROM archive_example.order_all WHERE order_id = 2)
   AND NOT (SELECT archived FROM archive_example.order_all WHERE order_id = 3) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A key lookup probes both tables; filtering on the flag removes the archive branch.
SELECT archive_example.plan_of('SELECT * FROM archive_example.order_all WHERE order_id = 2') AS id_plan \gset
SELECT archive_example.plan_of(
    'SELECT * FROM archive_example.order_all WHERE NOT archived AND order_id = 2') AS live_plan \gset
SELECT position('Append' IN :'id_plan') > 0
   AND position('orders_pkey' IN :'id_plan') > 0
   AND position('order_archive_pkey' IN :'id_plan') > 0
   AND position('Append' IN :'live_plan') = 0
   AND position('order_archive' IN :'live_plan') = 0 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The view is read-only: a UNION ALL view is not automatically updatable.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE archive_example.order_all SET status = 'open' WHERE order_id = 2;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '55000' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Restoring by copying leaves the order in both tiers.
SAVEPOINT copy_restore;
INSERT INTO archive_example.orders (order_id, customer_id, status, closed_at)
SELECT order_id, customer_id, status, closed_at
FROM archive_example.order_archive WHERE order_id = 2;
SELECT count(*) = 2 AS valid FROM archive_example.order_all WHERE order_id = 2 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- The next archive run then collides with the copy still in the archive.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT archive_example.archive_closed_orders(:'cutoff', 100);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
ROLLBACK TO SAVEPOINT copy_restore;

-- Schema drift since archiving: live orders gain a required column.
ALTER TABLE archive_example.orders ADD COLUMN channel text NOT NULL DEFAULT 'web';
ALTER TABLE archive_example.orders ALTER COLUMN channel DROP DEFAULT;
ALTER TABLE archive_example.order_archive ADD COLUMN channel text;

-- A restore that copies the archived columns as they are fails on the new rule.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
WITH restored_order AS (
    DELETE FROM archive_example.order_archive WHERE order_id = 2 RETURNING *
), restored_lines AS (
    DELETE FROM archive_example.order_line_archive WHERE order_id = 2 RETURNING *
), live_order AS (
    INSERT INTO archive_example.orders (order_id, customer_id, status, closed_at, channel)
    SELECT order_id, customer_id, status, closed_at, channel FROM restored_order
)
INSERT INTO archive_example.order_line (order_id, line_no, sku, amount)
SELECT order_id, line_no, sku, amount FROM restored_lines;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23502' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An explicit import moves the aggregate back and maps the old shape to the new one.
WITH restored_order AS (
    DELETE FROM archive_example.order_archive WHERE order_id = 2 RETURNING *
), restored_lines AS (
    DELETE FROM archive_example.order_line_archive WHERE order_id = 2 RETURNING *
), live_order AS (
    INSERT INTO archive_example.orders (order_id, customer_id, status, closed_at, channel)
    SELECT order_id, customer_id, status, closed_at, coalesce(channel, 'unknown')
    FROM restored_order
)
INSERT INTO archive_example.order_line (order_id, line_no, sku, amount)
SELECT order_id, line_no, sku, amount FROM restored_lines;
SELECT (SELECT channel FROM archive_example.orders WHERE order_id = 2) = 'unknown'
   AND (SELECT count(*) FROM archive_example.order_line WHERE order_id = 2) = 2
   AND NOT EXISTS (SELECT FROM archive_example.order_archive WHERE order_id = 2)
   AND NOT EXISTS (SELECT FROM archive_example.order_line_archive WHERE order_id = 2)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A restored order that is still closed and old qualifies for the next run.
SAVEPOINT rearchive;
SELECT archive_example.archive_closed_orders(:'cutoff', 100) = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
ROLLBACK TO SAVEPOINT rearchive;

-- Retention: archived orders closed more than seven years ago are deleted with their lines.
\set retain_after '2019-11-27 00:00+00'
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM archive_example.order_archive WHERE closed_at < :'retain_after';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH expired AS (
    DELETE FROM archive_example.order_archive
    WHERE closed_at < :'retain_after'
    RETURNING order_id
)
DELETE FROM archive_example.order_line_archive AS l
USING expired AS e
WHERE l.order_id = e.order_id;
SELECT NOT EXISTS (SELECT FROM archive_example.order_archive)
   AND NOT EXISTS (SELECT FROM archive_example.order_line_archive) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Partitioned variant: a partition that live rows still refer to cannot be detached.
CREATE TABLE archive_example.invoice (
    invoice_id bigint NOT NULL,
    issued_on date NOT NULL,
    PRIMARY KEY (invoice_id, issued_on)
) PARTITION BY RANGE (issued_on);
CREATE TABLE archive_example.invoice_2023 PARTITION OF archive_example.invoice
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE archive_example.invoice_2026 PARTITION OF archive_example.invoice
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE archive_example.payment (
    payment_id bigint PRIMARY KEY,
    invoice_id bigint NOT NULL,
    issued_on date NOT NULL,
    FOREIGN KEY (invoice_id, issued_on) REFERENCES archive_example.invoice
);
INSERT INTO archive_example.invoice VALUES (100, '2023-05-01'), (200, '2026-05-01');
INSERT INTO archive_example.payment VALUES (1000, 100, '2023-05-01'), (2000, 200, '2026-05-01');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
ALTER TABLE archive_example.invoice DETACH PARTITION archive_example.invoice_2023;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- Once no live row refers to the period, it detaches and stays readable under its own name.
DELETE FROM archive_example.payment WHERE issued_on < '2024-01-01';
ALTER TABLE archive_example.invoice DETACH PARTITION archive_example.invoice_2023;
SELECT (SELECT count(*) FROM archive_example.invoice) = 1
   AND (SELECT count(*) FROM archive_example.invoice_2023) = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
