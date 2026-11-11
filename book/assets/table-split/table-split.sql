-- Checked on PostgreSQL 18.6.
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
    \quit 1
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
    \quit 1
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
    \quit 1
\endif
DELETE FROM account WHERE account_id = 10;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM account_private);
END $$;
DELETE FROM product WHERE product_id = 1;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM product_detail) AND (SELECT count(*) = 1 FROM product);
END $$;
