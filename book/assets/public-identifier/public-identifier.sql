-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f public-identifier.sql in an empty database.
-- The duplicate-public-ID error is intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE customer (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint NOT NULL,
    public_id text COLLATE "C" NOT NULL
        DEFAULT ('cus_' || uuidv4()::text),
    display_name text NOT NULL,
    CONSTRAINT customer_public_id_key UNIQUE (public_id),
    CONSTRAINT customer_public_id_shape CHECK (
        public_id ~ '^cus_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    )
);
CREATE TABLE customer_order (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);

INSERT INTO customer (account_id, display_name)
VALUES (42, 'Northwind') RETURNING public_id;
-- Use a fixed, valid external ID for reproducible resolution and rotation.
INSERT INTO customer (account_id, public_id, display_name)
VALUES (42, 'cus_550e8400-e29b-41d4-a716-446655440000', 'Contoso');
INSERT INTO customer_order (customer_id)
SELECT customer_id FROM customer
WHERE public_id = 'cus_550e8400-e29b-41d4-a716-446655440000'
  AND account_id = 42;
SELECT c.customer_id, o.order_id FROM customer AS c
JOIN customer_order AS o USING (customer_id)
WHERE c.public_id = 'cus_550e8400-e29b-41d4-a716-446655440000'
  AND c.account_id = 42;
-- customer_id = 2, order_id = 1.

SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO customer (account_id, public_id, display_name)
VALUES (99, 'cus_550e8400-e29b-41d4-a716-446655440000', 'Duplicate');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

UPDATE customer SET public_id = 'cus_550e8400-e29b-41d4-a716-446655440001'
WHERE public_id = 'cus_550e8400-e29b-41d4-a716-446655440000'
  AND account_id = 42;
SELECT customer_id FROM customer_order WHERE order_id = 1;
-- customer_id is still 2; the previous public_id no longer resolves.

ROLLBACK;
