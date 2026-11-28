-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f dependent-table.sql in an empty disposable database.
-- The last section commits: it opens two extra connections to the same database
-- through dblink (same role, no password), creates the dblink and pgrowlocks
-- extensions in its own schema and drops that schema at the end.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA dependent_example;

-- Independent things: they exist without any order.
CREATE TABLE dependent_example.store (
    store_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE dependent_example.staff (
    store_id bigint NOT NULL REFERENCES dependent_example.store (store_id),
    staff_id bigint NOT NULL,
    name text NOT NULL,
    PRIMARY KEY (store_id, staff_id)
);
CREATE TABLE dependent_example.customer (
    customer_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE dependent_example.product (
    sku text PRIMARY KEY,
    name text NOT NULL
);

-- The owner: references independent things and links optionally to a sales rep.
CREATE TABLE dependent_example.customer_order (
    order_id bigint PRIMARY KEY,
    store_id bigint NOT NULL REFERENCES dependent_example.store (store_id),
    customer_id bigint NOT NULL
        REFERENCES dependent_example.customer (customer_id) ON DELETE RESTRICT,
    sales_rep_id bigint,
    FOREIGN KEY (store_id, sales_rep_id)
        REFERENCES dependent_example.staff (store_id, staff_id)
        ON DELETE SET NULL (sales_rep_id)
);
CREATE INDEX customer_order_customer_idx
    ON dependent_example.customer_order (customer_id);
CREATE INDEX customer_order_sales_rep_idx
    ON dependent_example.customer_order (store_id, sales_rep_id);

-- The dependent table: owned lines cascade, the product reference restricts
-- deletion and follows a corrected SKU.
CREATE TABLE dependent_example.order_line (
    order_id bigint NOT NULL
        REFERENCES dependent_example.customer_order (order_id) ON DELETE CASCADE,
    line_no integer NOT NULL,
    sku text NOT NULL
        REFERENCES dependent_example.product (sku)
        ON UPDATE CASCADE DEFERRABLE INITIALLY IMMEDIATE,
    quantity integer NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, line_no)
);

-- A row trigger on the child, to observe what cascades do.
CREATE TABLE dependent_example.order_line_removed (
    order_id bigint NOT NULL,
    line_no integer NOT NULL
);
CREATE FUNCTION dependent_example.record_removed_line() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dependent_example.order_line_removed VALUES (OLD.order_id, OLD.line_no);
    RETURN OLD;
END;
$$;
CREATE TRIGGER order_line_removed
    AFTER DELETE ON dependent_example.order_line
    FOR EACH ROW EXECUTE FUNCTION dependent_example.record_removed_line();

INSERT INTO dependent_example.store VALUES (1, 'Harbor');
INSERT INTO dependent_example.staff VALUES (1, 7, 'Ada'), (1, 8, 'Bo');
INSERT INTO dependent_example.customer VALUES (100, 'Meadow'), (101, 'Ridge');
INSERT INTO dependent_example.product
SELECT 'SKU-' || g, 'Product ' || g FROM generate_series(1, 1000) AS g;
INSERT INTO dependent_example.product VALUES
    ('TEA-01', 'Green tea'), ('CUP-01', 'Cup'),
    ('OLD-1', 'Unsold 1'), ('OLD-2', 'Unsold 2'), ('OLD-3', 'Unsold 3');
INSERT INTO dependent_example.customer_order VALUES
    (1, 1, 100, 7), (2, 1, 100, 8), (500, 1, 101, NULL);
INSERT INTO dependent_example.order_line VALUES
    (1, 1, 'TEA-01', 2), (1, 2, 'CUP-01', 1), (1, 3, 'TEA-01', 1),
    (2, 1, 'CUP-01', 4);
INSERT INTO dependent_example.order_line
SELECT 500, g, 'SKU-' || (g % 1000 + 1), 1 FROM generate_series(1, 20000) AS g;
ANALYZE dependent_example.product;
ANALYZE dependent_example.order_line;

-- Owned parts cascade, and the child's row trigger fires once per cascaded row.
DELETE FROM dependent_example.customer_order WHERE order_id = 1;
SELECT (SELECT count(*) FROM dependent_example.order_line WHERE order_id = 1) = 0
   AND (SELECT count(*) FROM dependent_example.order_line_removed WHERE order_id = 1) = 3
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A reference to an independent customer restricts deletion.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM dependent_example.customer WHERE customer_id = 100;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- NO ACTION (the default) on the product reference also rejects the delete.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM dependent_example.product WHERE sku = 'CUP-01';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- NO ACTION can be deferred: replacing a product row inside one transaction passes.
SAVEPOINT deferred_replace;
SET CONSTRAINTS ALL DEFERRED;
DELETE FROM dependent_example.product WHERE sku = 'CUP-01';
INSERT INTO dependent_example.product VALUES ('CUP-01', 'Cup, new supplier');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT (SELECT name FROM dependent_example.product WHERE sku = 'CUP-01')
       = 'Cup, new supplier' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
RELEASE SAVEPOINT deferred_replace;

-- RESTRICT is checked at once, even on a constraint declared deferred.
CREATE TABLE dependent_example.coupon (code text PRIMARY KEY);
CREATE TABLE dependent_example.coupon_use (
    code text NOT NULL REFERENCES dependent_example.coupon (code)
        ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);
INSERT INTO dependent_example.coupon VALUES ('SPRING');
INSERT INTO dependent_example.coupon_use VALUES ('SPRING');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM dependent_example.coupon WHERE code = 'SPRING';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- ON UPDATE CASCADE carries a corrected natural key into the lines.
UPDATE dependent_example.product SET sku = 'CUP-001' WHERE sku = 'CUP-01';
SELECT (SELECT sku FROM dependent_example.order_line WHERE order_id = 2 AND line_no = 1)
       = 'CUP-001' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- SET NULL (sales_rep_id) clears only the optional column of the composite key.
DELETE FROM dependent_example.staff WHERE store_id = 1 AND staff_id = 8;
SELECT (SELECT store_id = 1 AND sales_rep_id IS NULL
        FROM dependent_example.customer_order WHERE order_id = 2) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Plain SET NULL would also clear store_id, which is required.
CREATE TABLE dependent_example.delivery (
    delivery_id bigint PRIMARY KEY,
    store_id bigint NOT NULL REFERENCES dependent_example.store (store_id),
    courier_id bigint,
    FOREIGN KEY (store_id, courier_id)
        REFERENCES dependent_example.staff (store_id, staff_id) ON DELETE SET NULL
);
INSERT INTO dependent_example.delivery VALUES (1, 1, 7);
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM dependent_example.staff WHERE store_id = 1 AND staff_id = 7;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23502' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- SET DEFAULT must land on an existing parent: the default is checked like any value.
CREATE TABLE dependent_example.channel (code text PRIMARY KEY);
CREATE TABLE dependent_example.lead (
    lead_id bigint PRIMARY KEY,
    channel_code text NOT NULL DEFAULT 'web'
        REFERENCES dependent_example.channel (code) ON DELETE SET DEFAULT
);
INSERT INTO dependent_example.channel VALUES ('web'), ('phone');
INSERT INTO dependent_example.lead VALUES (1, 'phone'), (2, 'web');
DELETE FROM dependent_example.channel WHERE code = 'phone';
SELECT (SELECT channel_code FROM dependent_example.lead WHERE lead_id = 1) = 'web'
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM dependent_example.channel WHERE code = 'web';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Without an index on order_line (sku), every deleted product scans the lines once.
SELECT seq_scan AS seq_before, coalesce(idx_scan, 0) AS idx_before
FROM pg_stat_xact_user_tables
WHERE relid = 'dependent_example.order_line'::regclass \gset
DELETE FROM dependent_example.product WHERE sku IN ('OLD-1', 'OLD-2');
SELECT seq_scan - :seq_before = 2 AND coalesce(idx_scan, 0) = :idx_before AS valid
FROM pg_stat_xact_user_tables
WHERE relid = 'dependent_example.order_line'::regclass \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- With the index, the same check is an index probe.
CREATE INDEX order_line_sku_idx ON dependent_example.order_line (sku);
SELECT seq_scan AS seq_before, coalesce(idx_scan, 0) AS idx_before
FROM pg_stat_xact_user_tables
WHERE relid = 'dependent_example.order_line'::regclass \gset
DELETE FROM dependent_example.product WHERE sku = 'OLD-3';
SELECT seq_scan = :seq_before AND coalesce(idx_scan, 0) - :idx_before = 1 AS valid
FROM pg_stat_xact_user_tables
WHERE relid = 'dependent_example.order_line'::regclass \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A big tree: remove the children in bounded batches, then the owner.
-- In production each batch is its own transaction; here a loop stands in for it.
DO $$
DECLARE
    removed bigint;
    batches int := 0;
BEGIN
    LOOP
        DELETE FROM dependent_example.order_line
        WHERE (order_id, line_no) IN (
            SELECT order_id, line_no FROM dependent_example.order_line
            WHERE order_id = 500
            LIMIT 5000);
        GET DIAGNOSTICS removed = ROW_COUNT;
        EXIT WHEN removed = 0;
        batches := batches + 1;
        ASSERT removed <= 5000;
    END LOOP;
    ASSERT batches = 4;
END;
$$;
-- A line added between batches is still removed by the cascade of the final delete.
INSERT INTO dependent_example.order_line VALUES (500, 20001, 'SKU-1', 1);
DELETE FROM dependent_example.customer_order WHERE order_id = 500;
SELECT NOT EXISTS (SELECT FROM dependent_example.customer_order WHERE order_id = 500)
   AND NOT EXISTS (SELECT FROM dependent_example.order_line WHERE order_id = 500)
   AND (SELECT count(*) FROM dependent_example.order_line_removed WHERE order_id = 500) = 20001
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;

-- Concurrency: two more sessions through dblink, on committed tables.
CREATE SCHEMA dependent_race_example;
CREATE EXTENSION dblink SCHEMA dependent_race_example;
CREATE EXTENSION pgrowlocks SCHEMA dependent_race_example;
SET search_path = dependent_race_example, public;
CREATE TABLE customer_order (order_id bigint PRIMARY KEY, note text);
CREATE TABLE order_line (
    order_id bigint NOT NULL REFERENCES customer_order (order_id),
    line_no integer NOT NULL,
    PRIMARY KEY (order_id, line_no)
);
CREATE TABLE owned_line (
    order_id bigint NOT NULL REFERENCES customer_order (order_id) ON DELETE CASCADE,
    line_no integer NOT NULL,
    PRIMARY KEY (order_id, line_no)
);
INSERT INTO customer_order VALUES (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd');
SELECT dblink_connect('writer', 'dbname=' || current_database() || ' host=' || split_part(current_setting('unix_socket_directories'), ',', 1) || ' port=' || current_setting('port')) IS NOT NULL
   AND dblink_connect('deleter', 'dbname=' || current_database() || ' host=' || split_part(current_setting('unix_socket_directories'), ',', 1) || ' port=' || current_setting('port')) IS NOT NULL
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 1. The child insert comes first and takes FOR KEY SHARE on the parent row.
SELECT dblink_exec('writer', 'BEGIN') = 'BEGIN'
   AND dblink_exec('writer',
       'INSERT INTO dependent_race_example.order_line VALUES (1, 1)') = 'INSERT 0 1'
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT modes = ARRAY['For Key Share'] AS valid
FROM pgrowlocks('dependent_race_example.customer_order') AS l
JOIN customer_order AS o ON o.ctid = l.locked_row
WHERE o.order_id = 1 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- A non-key update of the parent does not wait for it.
SET lock_timeout = '1s';
UPDATE customer_order SET note = 'renamed' WHERE order_id = 1;
RESET lock_timeout;
-- The parent delete waits, then fails once the insert commits.
SELECT dblink_send_query('deleter',
       'DELETE FROM dependent_race_example.customer_order WHERE order_id = 1') = 1
   AS valid \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'valid'::boolean AND dblink_is_busy('deleter') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('writer', 'COMMIT') = 'COMMIT' AS valid \gset
-- dblink re-raises the remote error with its SQLSTATE.
\set ON_ERROR_STOP off
SELECT * FROM dblink_get_result('deleter') AS r (status text);
\set race_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'valid'::boolean AND :'race_state' = '23503'
   AND dblink_error_message('deleter') LIKE '%violates foreign key constraint "order_line_order_id_fkey"%'
   AS valid \gset
SELECT count(*) FROM dblink_get_result('deleter', false) AS r (status text) \gset ignored_
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 2. The parent delete comes first; the child insert waits, then fails.
SELECT dblink_exec('deleter', 'BEGIN') = 'BEGIN'
   AND dblink_exec('deleter',
       'DELETE FROM dependent_race_example.customer_order WHERE order_id = 2') = 'DELETE 1'
   AS valid \gset
SELECT dblink_send_query('writer',
       'INSERT INTO dependent_race_example.order_line VALUES (2, 1)') = 1
   AS sent \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'valid'::boolean AND :'sent'::boolean AND dblink_is_busy('writer') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('deleter', 'COMMIT') = 'COMMIT' AS valid \gset
-- dblink re-raises the remote error with its SQLSTATE.
\set ON_ERROR_STOP off
SELECT * FROM dblink_get_result('writer') AS r (status text);
\set race_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'valid'::boolean AND :'race_state' = '23503'
   AND dblink_error_message('writer') LIKE '%is not present in table "customer_order"%'
   AS valid \gset
SELECT count(*) FROM dblink_get_result('writer', false) AS r (status text) \gset ignored_
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 3. With CASCADE, the waiting delete succeeds and removes the line committed meanwhile.
SELECT dblink_exec('writer', 'BEGIN') = 'BEGIN'
   AND dblink_exec('writer',
       'INSERT INTO dependent_race_example.owned_line VALUES (3, 1)') = 'INSERT 0 1'
   AS valid \gset
SELECT dblink_send_query('deleter',
       'DELETE FROM dependent_race_example.customer_order WHERE order_id = 3') = 1
   AS sent \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'valid'::boolean AND :'sent'::boolean AND dblink_is_busy('deleter') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('writer', 'COMMIT') = 'COMMIT' AS valid \gset
SELECT :'valid'::boolean AND status = 'DELETE 1' AS valid
FROM dblink_get_result('deleter') AS r (status text) \gset
SELECT count(*) FROM dblink_get_result('deleter', false) AS r (status text) \gset ignored_
SELECT :'valid'::boolean AND NOT EXISTS (SELECT FROM owned_line WHERE order_id = 3) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 4. A cascade holds row locks on every child it deleted until it commits.
INSERT INTO owned_line SELECT 4, g FROM generate_series(1, 3) AS g;
SELECT dblink_exec('deleter', 'BEGIN') = 'BEGIN'
   AND dblink_exec('deleter',
       'DELETE FROM dependent_race_example.customer_order WHERE order_id = 4') = 'DELETE 1'
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
BEGIN;
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT * FROM owned_line WHERE order_id = 4 AND line_no = 3 FOR UPDATE NOWAIT;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
COMMIT;
SELECT :'rejected_state' = '55P03' AND dblink_exec('deleter', 'ROLLBACK') = 'ROLLBACK'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 5. An action cannot be altered in place; replace the constraint instead.
\set ON_ERROR_STOP off
ALTER TABLE order_line ALTER CONSTRAINT order_line_order_id_fkey ON DELETE CASCADE;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '42601' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
BEGIN;
SET LOCAL lock_timeout = '2s';
ALTER TABLE order_line DROP CONSTRAINT order_line_order_id_fkey;
SELECT count(*) = 2 AS valid FROM pg_locks
WHERE pid = pg_backend_pid() AND mode = 'AccessExclusiveLock'
  AND relation IN ('order_line'::regclass, 'customer_order'::regclass) \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
ALTER TABLE order_line ADD CONSTRAINT order_line_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES customer_order (order_id)
    ON DELETE CASCADE NOT VALID;
COMMIT;
-- NOT VALID postpones only the scan of old rows; the new action applies at once.
DELETE FROM customer_order WHERE order_id = 1;
SELECT NOT EXISTS (SELECT FROM order_line WHERE order_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
ALTER TABLE order_line VALIDATE CONSTRAINT order_line_order_id_fkey;
SELECT confdeltype = 'c' AND convalidated AS valid FROM pg_constraint
WHERE conrelid = 'order_line'::regclass AND conname = 'order_line_order_id_fkey' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SELECT dblink_disconnect('writer') = 'OK' AND dblink_disconnect('deleter') = 'OK' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
RESET search_path;
DROP SCHEMA dependent_race_example CASCADE;
