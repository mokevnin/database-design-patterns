-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f surrogate-key.sql in an empty database.
-- The duplicate-customer error is intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE customer (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_number text NOT NULL,
    display_name text NOT NULL,
    CONSTRAINT customer_number_key UNIQUE (customer_number)
);
CREATE TABLE customer_order (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);

INSERT INTO customer (customer_number, display_name)
VALUES ('C-104', 'Northwind') RETURNING customer_id;
INSERT INTO customer_order (customer_id)
SELECT customer_id FROM customer WHERE customer_number = 'C-104';
UPDATE customer SET customer_number = 'C-204'
WHERE customer_number = 'C-104';
SELECT o.order_id, c.customer_id, c.customer_number
FROM customer_order AS o JOIN customer AS c USING (customer_id);
-- order_id = 1, customer_id = 1, customer_number = C-204.

SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO customer (customer_number, display_name)
VALUES ('C-204', 'Duplicate');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- Isolated alternative implementations; do not add three PKs to customer.
CREATE TABLE random_customer (
    customer_id uuid PRIMARY KEY DEFAULT uuidv4()
);
CREATE TABLE ordered_customer (
    customer_id uuid PRIMARY KEY DEFAULT uuidv7()
);
INSERT INTO random_customer DEFAULT VALUES;
INSERT INTO ordered_customer DEFAULT VALUES;
SELECT uuid_extract_version(customer_id) = 4 AS is_v4 FROM random_customer;
SELECT uuid_extract_version(customer_id) = 7 AS is_v7 FROM ordered_customer;

ROLLBACK;
