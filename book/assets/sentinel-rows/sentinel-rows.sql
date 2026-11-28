-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f sentinel-rows.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA sentinel_example;
SET LOCAL search_path TO sentinel_example;

-- Before: a fake customer satisfies a mandatory reference.
CREATE TABLE customer (
    customer_id bigint PRIMARY KEY,
    name text NOT NULL,
    email text NOT NULL,
    credit_limit numeric(12,2) NOT NULL DEFAULT 0
);
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id),
    total numeric(12,2) NOT NULL CHECK (total > 0)
);
CREATE TABLE customer_login (
    login text PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
INSERT INTO customer VALUES
    (0, 'Unknown', 'noreply@shop.example', 1000.00),
    (1, 'Harbor', 'buyer@harbor.example', 5000.00),
    (2, 'Meadow', 'orders@meadow.example', 2000.00);
INSERT INTO customer_order VALUES
    (101, 1, 400.00), (102, 1, 350.00), (103, 2, 300.00),
    (104, 0, 200.00), (105, 0, 250.00), (106, 0, 180.00);

-- The NOT NULL column and the FK both accept an order whose customer is missing.
INSERT INTO customer_order VALUES (107, 0, 220.00);
SELECT count(*) = 4 AS valid FROM customer_order WHERE customer_id = 0 \gset
\if :valid
\else
    \quit 1
\endif

-- A shared kiosk login was linked to the fake customer and sees every guest order.
INSERT INTO customer_login VALUES ('kiosk', 0), ('harbor-buyer', 1);
SELECT count(*) = 4 AS valid
FROM customer_order AS o JOIN customer_login AS l USING (customer_id)
WHERE l.login = 'kiosk' \gset
\if :valid
\else
    \quit 1
\endif

-- Guest orders inherit the attributes someone gave the fake customer.
SELECT (SELECT c.credit_limit FROM customer_order AS o JOIN customer AS c USING (customer_id)
        WHERE o.order_id = 104) = 1000.00 AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- The fake customer becomes the biggest customer.
SELECT c.name, sum(o.total) AS revenue
FROM customer_order AS o JOIN customer AS c USING (customer_id)
GROUP BY c.name ORDER BY revenue DESC;
SELECT (SELECT c.name FROM customer_order AS o JOIN customer AS c USING (customer_id)
        GROUP BY c.name ORDER BY sum(o.total) DESC LIMIT 1) = 'Unknown' AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- A second team adds its own placeholder; the old filter does not know about it.
INSERT INTO customer VALUES (-1, 'N/A', 'n/a@shop.example', 0);
INSERT INTO customer_order VALUES (108, -1, 90.00);
SELECT count(DISTINCT customer_id) = 4 AS valid FROM customer_order \gset
\if :valid
\else
    \quit 1
\endif
SELECT count(DISTINCT customer_id) = 3 AS valid
FROM customer_order WHERE customer_id <> 0 \gset
\if :valid
\else
    \quit 1
\endif

-- Code that finds the placeholder by its label breaks when someone renames it.
SAVEPOINT renamed;
UPDATE customer SET name = 'Guest' WHERE customer_id = 0;
SELECT count(*) = 0 AS valid
FROM customer_order AS o JOIN customer AS c USING (customer_id)
WHERE c.name = 'Unknown' \gset
\if :valid
\else
    \quit 1
\endif
ROLLBACK TO SAVEPOINT renamed;

-- The fake row cannot be removed while orders and logins point at it.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM customer WHERE customer_id = 0;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- Migration step 1: inventory every reference to the customer table.
SELECT c.conrelid::regclass AS referencing_table, a.attname AS referencing_column
FROM pg_constraint AS c
JOIN pg_attribute AS a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
WHERE c.contype = 'f' AND c.confrelid = 'customer'::regclass
ORDER BY 1::text;
SELECT count(*) = 2 AS valid
FROM pg_constraint
WHERE contype = 'f' AND confrelid = 'customer'::regclass \gset
\if :valid
\else
    \quit 1
\endif

-- Migration step 2: name what each magic row meant.
CREATE TABLE sentinel_map (
    customer_id bigint PRIMARY KEY,
    missing_reason text NOT NULL
);
INSERT INTO sentinel_map VALUES (0, 'not_provided'), (-1, 'not_applicable');

-- Migration step 3 (expand): allow an absent customer, but only with a reason.
ALTER TABLE customer_order
    ALTER COLUMN customer_id DROP NOT NULL,
    ADD COLUMN customer_missing_reason text,
    ADD CONSTRAINT customer_order_missing_reason_check
        CHECK (customer_missing_reason IN ('not_provided', 'not_applicable', 'withheld')) NOT VALID,
    ADD CONSTRAINT customer_order_customer_presence
        CHECK ((customer_id IS NULL) <> (customer_missing_reason IS NULL)) NOT VALID;

-- During the compatibility window, old and new writers both succeed.
SAVEPOINT compatibility_window;
INSERT INTO customer_order (order_id, customer_id, total) VALUES (120, 0, 10.00);
INSERT INTO customer_order (order_id, customer_id, total, customer_missing_reason)
VALUES (121, NULL, 10.00, 'not_provided');
SELECT count(*) = 2 AS valid FROM customer_order WHERE order_id IN (120, 121) \gset
\if :valid
\else
    \quit 1
\endif
ROLLBACK TO SAVEPOINT compatibility_window;

-- Migration step 4 (guard): once writers store NULL plus a reason,
-- reject new writes to the magic IDs before the backfill.
ALTER TABLE customer_order
    ADD CONSTRAINT customer_order_no_sentinel CHECK (customer_id NOT IN (0, -1)) NOT VALID;

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_order (order_id, customer_id, total) VALUES (109, 0, 75.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- Migration step 5: map references to NULL plus a reason; remove access grants.
UPDATE customer_order AS o
SET customer_id = NULL, customer_missing_reason = m.missing_reason
FROM sentinel_map AS m
WHERE o.customer_id = m.customer_id;
DELETE FROM customer_login AS l USING sentinel_map AS m
WHERE l.customer_id = m.customer_id;

-- Migration step 6: validate, then retire the rows; the delete proves no reference is left.
ALTER TABLE customer_order VALIDATE CONSTRAINT customer_order_missing_reason_check;
ALTER TABLE customer_order VALIDATE CONSTRAINT customer_order_customer_presence;
ALTER TABLE customer_order VALIDATE CONSTRAINT customer_order_no_sentinel;
DELETE FROM customer AS c USING sentinel_map AS m WHERE c.customer_id = m.customer_id;
SELECT (SELECT count(*) FROM customer) = 2
   AND (SELECT bool_and(convalidated) FROM pg_constraint
        WHERE conrelid = 'customer_order'::regclass AND contype = 'c') AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- After: the customer ranking contains customers only.
SELECT c.name, sum(o.total) AS revenue
FROM customer_order AS o JOIN customer AS c USING (customer_id)
GROUP BY c.name ORDER BY revenue DESC;
SELECT (SELECT c.name FROM customer_order AS o JOIN customer AS c USING (customer_id)
        GROUP BY c.name ORDER BY sum(o.total) DESC LIMIT 1) = 'Harbor'
   AND (SELECT count(DISTINCT customer_id) FROM customer_order) = 2 AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- Unattributed revenue is reported separately, by reason, and nothing is lost.
SELECT customer_missing_reason, count(*) AS orders, sum(total) AS revenue
FROM customer_order WHERE customer_id IS NULL
GROUP BY customer_missing_reason ORDER BY customer_missing_reason;
SELECT (SELECT sum(total) FROM customer_order WHERE customer_missing_reason = 'not_provided') = 850.00
   AND (SELECT sum(total) FROM customer_order WHERE customer_missing_reason = 'not_applicable') = 90.00
   AND (SELECT sum(o.total) FROM customer_order AS o JOIN customer AS c USING (customer_id)) = 1050.00
   AND (SELECT sum(total) FROM customer_order) = 1990.00 AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- The kiosk login no longer sees anyone's orders.
SELECT count(*) = 0 AS valid
FROM customer_order AS o JOIN customer_login AS l USING (customer_id)
WHERE l.login = 'kiosk' \gset
\if :valid
\else
    \quit 1
\endif

-- A guest order is accepted with a reason.
INSERT INTO customer_order (order_id, customer_id, total, customer_missing_reason)
VALUES (110, NULL, 60.00, 'withheld');

-- Absent customer without a reason is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_order (order_id, customer_id, total) VALUES (111, NULL, 50.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- A customer and a reason together are rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_order (order_id, customer_id, total, customer_missing_reason)
VALUES (112, 1, 50.00, 'withheld');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- A reason outside the vocabulary is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_order (order_id, customer_id, total, customer_missing_reason)
VALUES (113, NULL, 50.00, 'unknown');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- A magic ID is rejected by the guard.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_order (order_id, customer_id, total) VALUES (114, 0, 50.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- NULL has its own trap: inequality drops absent customers, IS DISTINCT FROM keeps them.
SELECT (SELECT count(*) FROM customer_order WHERE customer_id <> 1) = 1
   AND (SELECT count(*) FROM customer_order WHERE customer_id IS DISTINCT FROM 1) = 7 AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- Alternative: absence is a state of the owning row, legal only while a quote is a draft.
CREATE TABLE quote (
    quote_id bigint PRIMARY KEY,
    status text NOT NULL CHECK (status IN ('draft', 'issued')),
    customer_id bigint REFERENCES customer (customer_id),
    CONSTRAINT quote_issued_has_customer CHECK (status = 'draft' OR customer_id IS NOT NULL)
);
INSERT INTO quote VALUES (1, 'draft', NULL);
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE quote SET status = 'issued' WHERE quote_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
UPDATE quote SET status = 'issued', customer_id = 2 WHERE quote_id = 1;

-- Defensible: a real, named service actor that takes part in the domain.
CREATE TABLE actor (
    actor_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('person', 'service')),
    code text NOT NULL UNIQUE,
    display_name text NOT NULL
);
CREATE TABLE price_change (
    change_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id bigint NOT NULL REFERENCES actor (actor_id),
    new_price numeric(12,2) NOT NULL
);
INSERT INTO actor (kind, code, display_name) VALUES
    ('service', 'system.repricer', 'Nightly repricing job'),
    ('person', 'anna', 'Anna Petrova');
INSERT INTO price_change (actor_id, new_price)
SELECT actor_id, 19.90 FROM actor WHERE code = 'system.repricer';
INSERT INTO price_change (actor_id, new_price)
SELECT actor_id, 21.50 FROM actor WHERE code = 'anna';
SELECT (SELECT count(*) FROM price_change AS p JOIN actor AS a USING (actor_id)
        WHERE a.kind = 'person') = 1
   AND (SELECT count(*) FROM price_change) = 2 AS valid \gset
\if :valid
\else
    \quit 1
\endif

ROLLBACK;
