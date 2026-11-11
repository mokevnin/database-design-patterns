-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f expand-contract.sql in an empty database.
-- Intentional errors are checked by SQLSTATE; unexpected failures stop the script.
-- Creates the isolated expand_contract_example schema and leaves it for inspection.
\set ON_ERROR_STOP on
CREATE SCHEMA expand_contract_example;
SET search_path = expand_contract_example, public;

CREATE TABLE customer (
    customer_id bigint PRIMARY KEY,
    full_name text NOT NULL
);
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
INSERT INTO customer VALUES (1, 'Harbor'), (2, 'Meadow');
INSERT INTO customer_order VALUES (10, 1);

BEGIN;
SET LOCAL lock_timeout = '1s';
ALTER TABLE customer ADD COLUMN display_name text;
CREATE FUNCTION bridge_customer_name() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.full_name := coalesce(NEW.full_name, NEW.display_name);
        NEW.display_name := coalesce(NEW.display_name, NEW.full_name);
    ELSE
        IF NEW.full_name IS DISTINCT FROM OLD.full_name
           AND NEW.display_name IS NOT DISTINCT FROM OLD.display_name THEN
            NEW.display_name := NEW.full_name;
        ELSIF NEW.display_name IS DISTINCT FROM OLD.display_name
           AND NEW.full_name IS NOT DISTINCT FROM OLD.full_name THEN
            NEW.full_name := NEW.display_name;
        ELSIF NEW.display_name IS NULL
           AND NEW.full_name IS NOT DISTINCT FROM OLD.full_name
           AND NEW.display_name IS NOT DISTINCT FROM OLD.display_name THEN
            NEW.display_name := NEW.full_name;
        END IF;
    END IF;
    IF NEW.full_name IS DISTINCT FROM NEW.display_name THEN
        RAISE EXCEPTION 'customer names must agree' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER customer_name_bridge
BEFORE INSERT OR UPDATE ON customer
FOR EACH ROW EXECUTE FUNCTION bridge_customer_name();
COMMIT;

WITH batch AS (
    SELECT customer_id FROM customer
    WHERE display_name IS NULL
    ORDER BY customer_id LIMIT 100
    FOR UPDATE SKIP LOCKED
)
UPDATE customer AS c SET display_name = c.full_name
FROM batch AS b WHERE c.customer_id = b.customer_id;
UPDATE customer SET full_name = 'Harbor Shop' WHERE customer_id = 1;
INSERT INTO customer (customer_id, display_name) VALUES (3, 'Brook');
SELECT customer_id, full_name, display_name FROM customer ORDER BY customer_id;

SELECT (SELECT count(*) = 3 AND bool_and(full_name = display_name) FROM customer) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
UPDATE customer SET full_name = 'Old choice', display_name = 'New choice'
WHERE customer_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '23514') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;


ALTER TABLE customer ADD CONSTRAINT customer_display_ready
    CHECK (display_name IS NOT NULL) NOT VALID;
ALTER TABLE customer VALIDATE CONSTRAINT customer_display_ready;
ALTER TABLE customer ALTER COLUMN display_name SET NOT NULL;
ALTER TABLE customer DROP CONSTRAINT customer_display_ready;
SELECT count(*) AS mismatches FROM customer
WHERE full_name IS DISTINCT FROM display_name;

-- A write to an already backfilled row through the new name.
UPDATE customer SET display_name = 'Meadow Shop' WHERE customer_id = 2;

SELECT (SELECT full_name = 'Meadow Shop' FROM customer WHERE customer_id = 2) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


BEGIN;
SET LOCAL lock_timeout = '1s';
DROP TRIGGER customer_name_bridge ON customer;
ALTER TABLE customer DROP COLUMN full_name;
DROP FUNCTION bridge_customer_name();
COMMIT;
UPDATE customer SET display_name = 'Harbor Market' WHERE customer_id = 1;
SELECT o.order_id, c.display_name
FROM customer_order AS o JOIN customer AS c USING (customer_id);

SELECT (SELECT c.display_name = 'Harbor Market' FROM customer_order AS o JOIN customer AS c USING (customer_id) WHERE o.order_id = 10) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


-- Split variant: old shape before expansion.
CREATE TABLE product (
    product_id bigint PRIMARY KEY,
    name text NOT NULL,
    specification text NOT NULL
);
INSERT INTO product VALUES (1, 'Chair', 'Oak frame'), (2, 'Desk', 'Pine top');
BEGIN;
SET LOCAL lock_timeout = '1s';

CREATE TABLE product_detail (
    product_id bigint PRIMARY KEY REFERENCES product (product_id) ON DELETE CASCADE,
    specification text NOT NULL
);
CREATE FUNCTION mirror_product_detail() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO product_detail VALUES (NEW.product_id, NEW.specification)
    ON CONFLICT (product_id) DO UPDATE SET specification = EXCLUDED.specification;
    RETURN NULL;
END $$;
CREATE TRIGGER product_detail_bridge AFTER INSERT OR UPDATE ON product
FOR EACH ROW EXECUTE FUNCTION mirror_product_detail();
WITH batch AS (
    SELECT product_id, specification FROM product
    WHERE NOT EXISTS (
        SELECT FROM product_detail AS d WHERE d.product_id = product.product_id
    )
    ORDER BY product_id LIMIT 100 FOR UPDATE OF product SKIP LOCKED
)
INSERT INTO product_detail SELECT * FROM batch
ON CONFLICT (product_id) DO UPDATE SET specification = EXCLUDED.specification;

COMMIT;

SELECT (SELECT count(*) = 2 AND bool_and(p.specification = d.specification) FROM product AS p JOIN product_detail AS d USING (product_id)) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


UPDATE product SET specification = 'Ash frame' WHERE product_id = 1;
INSERT INTO product VALUES (3, 'Stool', 'Beech legs');
DELETE FROM product WHERE product_id = 3;

SELECT (SELECT specification = 'Ash frame' FROM product_detail WHERE product_id = 1) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


SELECT (SELECT NOT EXISTS (SELECT FROM product_detail WHERE product_id = 3)) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


-- Read switch gate: no missing or mismatched extensions.
SELECT p.product_id FROM product AS p LEFT JOIN product_detail AS d USING (product_id)
WHERE p.specification IS DISTINCT FROM d.specification;
-- All old writers have retired before this contract transaction.
BEGIN;
SET LOCAL lock_timeout = '1s';
DROP TRIGGER product_detail_bridge ON product;
ALTER TABLE product DROP COLUMN specification;
DROP FUNCTION mirror_product_detail();
COMMIT;
UPDATE product_detail SET specification = 'Steel frame' WHERE product_id = 1;

SELECT (SELECT d.specification = 'Steel frame' FROM product AS p JOIN product_detail AS d USING (product_id) WHERE p.product_id = 1) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


-- Type variant: old values remain representable until contraction.
CREATE TABLE stock (stock_id bigint PRIMARY KEY, units integer NOT NULL);
INSERT INTO stock VALUES (1, 12), (2, 20);
BEGIN;
SET LOCAL lock_timeout = '1s';

ALTER TABLE stock ADD COLUMN units_big bigint;
CREATE FUNCTION mirror_stock_units() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.units_big := NEW.units;
    RETURN NEW;
END $$;
CREATE TRIGGER stock_units_bridge BEFORE INSERT OR UPDATE ON stock
FOR EACH ROW EXECUTE FUNCTION mirror_stock_units();
UPDATE stock SET units_big = units;
ALTER TABLE stock ADD CONSTRAINT stock_units_agree
    CHECK (units_big IS NOT NULL AND units_big = units) NOT VALID;
ALTER TABLE stock VALIDATE CONSTRAINT stock_units_agree;
ALTER TABLE stock ALTER COLUMN units_big SET NOT NULL;

COMMIT;

UPDATE stock SET units = 15 WHERE stock_id = 1;

SELECT (SELECT bool_and(units_big = units) FROM stock) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO stock (stock_id, units) VALUES (3, 2147483648);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '22003') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;


-- Retire old-compatible writers, then remove the old contract.
BEGIN;
SET LOCAL lock_timeout = '1s';
ALTER TABLE stock DROP CONSTRAINT stock_units_agree;
DROP TRIGGER stock_units_bridge ON stock;
ALTER TABLE stock DROP COLUMN units;
DROP FUNCTION mirror_stock_units();
COMMIT;
UPDATE stock SET units_big = 2147483648 WHERE stock_id = 1;

SELECT (SELECT units_big = 2147483648 FROM stock WHERE stock_id = 1) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif

