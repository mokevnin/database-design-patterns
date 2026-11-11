-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f missing-foreign-keys.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA missing_foreign_keys_lab;
SET search_path TO missing_foreign_keys_lab, public;

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

CREATE TABLE customer (customer_id bigint PRIMARY KEY, name text NOT NULL);
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL
);
INSERT INTO customer VALUES (1, 'Harbor'), (2, 'Meadow');
INSERT INTO customer_order VALUES (10, 1), (20, 2);
DELETE FROM customer WHERE customer_id = 2;
SELECT o.order_id, o.customer_id FROM customer_order AS o
LEFT JOIN customer AS c USING (customer_id) WHERE c.customer_id IS NULL;

CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);
ALTER TABLE customer_order ADD CONSTRAINT customer_order_customer_fk
    FOREIGN KEY (customer_id) REFERENCES customer (customer_id) NOT VALID;

SELECT pg_temp.expect_error($operation$INSERT INTO customer_order VALUES (30, 999);$operation$, '23503', 'insert or update on table "customer_order" violates foreign key constraint "customer_order_customer_fk"');

CREATE TABLE order_reject (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    reason text NOT NULL
);
BEGIN;
LOCK TABLE customer_order, customer IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO order_reject
SELECT o.order_id, o.customer_id, 'missing customer'
FROM customer_order AS o LEFT JOIN customer AS c USING (customer_id)
WHERE c.customer_id IS NULL;
DELETE FROM customer_order AS o USING order_reject AS r
WHERE o.order_id = r.order_id;
COMMIT;
ALTER TABLE customer_order VALIDATE CONSTRAINT customer_order_customer_fk;
SELECT order_id, customer_id FROM customer_order ORDER BY order_id;
SELECT * FROM order_reject ORDER BY order_id;

SELECT pg_temp.expect_error($operation$DELETE FROM customer WHERE customer_id = 1;$operation$, '23503', 'update or delete on table "customer" violates foreign key constraint "customer_order_customer_fk" on table "customer_order"');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 1 FROM customer_order);
    ASSERT (SELECT count(*) = 1 FROM order_reject);
    ASSERT (SELECT convalidated FROM pg_constraint
        WHERE conrelid = 'customer_order'::regclass AND conname = 'customer_order_customer_fk');
END $$;
