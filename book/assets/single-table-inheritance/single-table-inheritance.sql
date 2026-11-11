-- Checked on PostgreSQL 18.6. Run with psql -X -v ON_ERROR_STOP=1 -f this-file.sql.
-- The lab rolls back its objects. Expected failures are asserted in subtransactions.
BEGIN;
CREATE SCHEMA sti_lab;
SET LOCAL search_path = sti_lab, public;

CREATE TABLE customer (
    customer_id bigint PRIMARY KEY,
    customer_number text NOT NULL UNIQUE,
    kind text NOT NULL CHECK (kind IN ('person', 'company')),
    display_name text NOT NULL,
    birth_date date,
    registration_number text,
    CONSTRAINT customer_shape CHECK (
        (kind = 'person' AND birth_date IS NOT NULL AND registration_number IS NULL)
        OR
        (kind = 'company' AND birth_date IS NULL AND registration_number IS NOT NULL)
    )
);
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);

INSERT INTO customer VALUES
    (1, 'C-1', 'person', 'Ada', DATE '1990-01-01', NULL),
    (2, 'C-2', 'company', 'Northwind', NULL, 'REG-2');
INSERT INTO customer_order VALUES (10, 1), (20, 2);
SELECT customer_number, kind, display_name FROM customer ORDER BY customer_id;
UPDATE customer SET display_name = 'Ada Lovelace' WHERE customer_id = 1;
DO $$
BEGIN
    BEGIN
        UPDATE customer SET kind = 'company' WHERE customer_id = 1;
        RAISE EXCEPTION 'Expected customer_shape rejection';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'new row for relation "customer" violates check constraint "customer_shape"' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
UPDATE customer
SET kind = 'company', birth_date = NULL, registration_number = 'REG-1'
WHERE customer_id = 1;
SELECT o.order_id, c.kind, c.registration_number
FROM customer_order AS o JOIN customer AS c USING (customer_id)
WHERE o.order_id = 10;
ROLLBACK;
