-- Checked on PostgreSQL 18.6. Run with psql -X -v ON_ERROR_STOP=1 -f this-file.sql.
BEGIN;
CREATE SCHEMA concrete_lab;
SET LOCAL search_path = concrete_lab, public;

CREATE SEQUENCE customer_ids AS bigint;
CREATE TABLE person_customer (
    customer_id bigint PRIMARY KEY DEFAULT nextval('customer_ids'),
    customer_number text NOT NULL UNIQUE,
    display_name text NOT NULL,
    birth_date date NOT NULL
);
CREATE TABLE company_customer (
    customer_id bigint PRIMARY KEY DEFAULT nextval('customer_ids'),
    customer_number text NOT NULL UNIQUE,
    display_name text NOT NULL,
    registration_number text NOT NULL UNIQUE
);
CREATE TABLE company_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES company_customer (customer_id)
);
CREATE INDEX company_order_customer_idx ON company_order (customer_id);
CREATE VIEW all_customers AS
SELECT customer_id, 'person'::text AS kind, customer_number, display_name
FROM person_customer
UNION ALL
SELECT customer_id, 'company'::text AS kind, customer_number, display_name
FROM company_customer;

INSERT INTO person_customer (customer_number, display_name, birth_date)
VALUES ('P-1', 'Ada', DATE '1990-01-01');
INSERT INTO company_customer (customer_number, display_name, registration_number)
VALUES ('C-1', 'Northwind', 'REG-2');
INSERT INTO company_order VALUES (10, 2);
SELECT customer_id, kind, display_name FROM all_customers ORDER BY customer_id;
UPDATE company_customer SET display_name = 'Northwind Ltd' WHERE customer_id = 2;
DO $$
BEGIN
    BEGIN
        INSERT INTO company_order VALUES (11, 1);
        RAISE EXCEPTION 'Expected subtype-specific FK rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        IF SQLERRM <> 'insert or update on table "company_order" violates foreign key constraint "company_order_customer_id_fkey"' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
-- A shared allocator is not a cross-table uniqueness constraint.
INSERT INTO company_customer (customer_id, customer_number, display_name, registration_number)
VALUES (1, 'P-1', 'Collision demonstration', 'REG-X');
SELECT customer_id, count(*) FROM all_customers GROUP BY customer_id HAVING count(*) > 1;
ROLLBACK;
