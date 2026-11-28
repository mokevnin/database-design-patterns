-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f table-split.sql in an empty database.
-- Expected errors are intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on

CREATE TABLE product (
    product_id bigint PRIMARY KEY,
    sku text NOT NULL UNIQUE,
    name text NOT NULL
);
CREATE TABLE product_detail (
    product_id bigint PRIMARY KEY REFERENCES product (product_id)
        ON DELETE CASCADE,
    specification text NOT NULL
);
INSERT INTO product VALUES (1, 'CHAIR', 'Chair'), (2, 'DESK', 'Desk');
INSERT INTO product_detail VALUES (1, 'Oak frame');
SELECT p.sku, d.specification FROM product AS p
LEFT JOIN product_detail AS d USING (product_id)
ORDER BY p.product_id;
UPDATE product_detail SET specification = 'Ash frame' WHERE product_id = 1;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
INSERT INTO product_detail VALUES (1, 'Another specification');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
CREATE TABLE account (
    account_id bigint PRIMARY KEY,
    display_name text NOT NULL
);
CREATE TABLE account_private (
    account_id bigint PRIMARY KEY REFERENCES account (account_id)
        ON DELETE CASCADE,
    billing_reference text NOT NULL
);
ALTER TABLE account ADD CONSTRAINT account_requires_private
    FOREIGN KEY (account_id) REFERENCES account_private (account_id)
    DEFERRABLE INITIALLY DEFERRED;
BEGIN;
INSERT INTO account VALUES (10, 'Northwind');
INSERT INTO account_private VALUES (10, 'B-10');
COMMIT;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
BEGIN;
INSERT INTO account VALUES (11, 'Incomplete');
COMMIT;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM account WHERE account_id = 11);
END $$;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
DELETE FROM account_private WHERE account_id = 10;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
DELETE FROM account WHERE account_id = 10;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM account_private);
END $$;
DELETE FROM product WHERE product_id = 1;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM product_detail) AND (SELECT count(*) = 1 FROM product);
END $$;

-- Personal data in an optional extension can be erased while references stay valid.
CREATE TABLE customer (customer_id bigint PRIMARY KEY);
CREATE TABLE customer_contact (
    customer_id bigint PRIMARY KEY REFERENCES customer (customer_id) ON DELETE CASCADE,
    full_name text NOT NULL,
    email text NOT NULL
);
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
INSERT INTO customer VALUES (7);
INSERT INTO customer_contact VALUES (7, 'Ada Lovelace', 'ada@example.com');
INSERT INTO customer_order VALUES (70, 7);
DELETE FROM customer_contact WHERE customer_id = 7;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 1 FROM customer_order AS o
            LEFT JOIN customer_contact AS c USING (customer_id)
            WHERE o.order_id = 70 AND c.customer_id IS NULL);
    ASSERT (SELECT count(*) = 0 FROM customer_contact);
END $$;
