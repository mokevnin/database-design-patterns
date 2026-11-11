-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f cloned-tables.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA cloned_tables_lab;
SET search_path TO cloned_tables_lab, public;

CREATE OR REPLACE FUNCTION pg_temp.expect_error(command text, expected_state text, expected_message text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual_state text;
    actual_message text;
BEGIN
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE,
            actual_message = MESSAGE_TEXT;
    END;
    IF actual_state IS DISTINCT FROM expected_state
       OR actual_message IS DISTINCT FROM expected_message THEN
        RAISE EXCEPTION 'Expected %: %, got %: %', expected_state,
            expected_message, actual_state, actual_message;
    END IF;
    RAISE NOTICE 'Expected %: %', actual_state, actual_message;
END;
$$;

CREATE TABLE customer (customer_id bigint PRIMARY KEY);
CREATE TABLE orders_2025 (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id),
    placed_on date NOT NULL
);
CREATE TABLE orders_2026 (LIKE orders_2025 INCLUDING ALL);
ALTER TABLE orders_2026 ADD FOREIGN KEY (customer_id) REFERENCES customer (customer_id);
INSERT INTO customer VALUES (1);
INSERT INTO orders_2025 VALUES (100, 1, DATE '2025-12-31');
INSERT INTO orders_2026 VALUES (200, 1, DATE '2026-01-01');
SELECT count(*) FROM orders_2025;
SELECT count(*) FROM (
    SELECT order_id FROM orders_2025
    UNION ALL SELECT order_id FROM orders_2026
) AS all_orders;
INSERT INTO orders_2026 VALUES (100, 1, DATE '2026-02-01');
SELECT order_id, count(*) FROM (
    SELECT order_id FROM orders_2025
    UNION ALL SELECT order_id FROM orders_2026
) AS all_orders GROUP BY order_id HAVING count(*) > 1;

CREATE TABLE sales_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id),
    placed_on date NOT NULL
);
CREATE INDEX sales_order_customer_day_idx ON sales_order (customer_id, placed_on);
CREATE TABLE order_id_review (
    source_table text NOT NULL,
    old_order_id bigint NOT NULL,
    new_order_id bigint NOT NULL UNIQUE,
    PRIMARY KEY (source_table, old_order_id)
);
-- Reviewed mapping: the two old order 100 rows are distinct orders in this lab.
INSERT INTO order_id_review VALUES
    ('orders_2025', 100, 100), ('orders_2026', 200, 200), ('orders_2026', 100, 300);
BEGIN;
LOCK TABLE orders_2025, orders_2026 IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO sales_order
SELECT m.new_order_id, o.customer_id, o.placed_on FROM orders_2025 AS o
JOIN order_id_review AS m ON m.source_table = 'orders_2025' AND m.old_order_id = o.order_id
UNION ALL
SELECT m.new_order_id, o.customer_id, o.placed_on FROM orders_2026 AS o
JOIN order_id_review AS m ON m.source_table = 'orders_2026' AND m.old_order_id = o.order_id;
COMMIT;
SELECT count(*) FROM sales_order;
SELECT order_id FROM sales_order
WHERE customer_id = 1 AND placed_on >= DATE '2026-01-01' ORDER BY order_id;

SELECT pg_temp.expect_error($operation$INSERT INTO sales_order VALUES (100, 1, DATE '2027-01-01');$operation$, '23505', 'duplicate key value violates unique constraint "sales_order_pkey"');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 3 FROM sales_order);
    ASSERT (SELECT count(*) = 3 FROM order_id_review);
END $$;
