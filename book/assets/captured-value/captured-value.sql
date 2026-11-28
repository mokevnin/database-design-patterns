-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f captured-value.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
-- The script creates a captured_value_app role inside its transaction; ROLLBACK removes it.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA captured_example;
SET LOCAL search_path = captured_example, public;

-- Sources: current descriptive values and dated prices.
CREATE TABLE customer (
    customer_id bigint PRIMARY KEY,
    billing_address text NOT NULL
);
CREATE TABLE product (
    product_id bigint PRIMARY KEY,
    name text NOT NULL,
    tax_rate numeric(5,4) NOT NULL CHECK (tax_rate >= 0 AND tax_rate < 1)
);
CREATE TABLE product_price (
    price_id bigint NOT NULL UNIQUE,
    product_id bigint NOT NULL REFERENCES product (product_id),
    currency text NOT NULL,
    valid_at daterange NOT NULL CHECK (NOT lower_inf(valid_at)),
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    CONSTRAINT product_price_no_overlap
        PRIMARY KEY (product_id, currency, valid_at WITHOUT OVERLAPS)
);

-- The fact: an order whose captured columns freeze at confirmation.
CREATE TABLE sales_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id),
    currency text NOT NULL,
    order_date date NOT NULL,
    state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'confirmed')),
    billing_address text,
    confirmed_at timestamptz,
    UNIQUE (order_id, currency),
    CHECK (state = 'draft' OR (billing_address IS NOT NULL AND confirmed_at IS NOT NULL))
);
CREATE TABLE order_line (
    order_id bigint NOT NULL,
    line_no integer NOT NULL,
    product_id bigint NOT NULL REFERENCES product (product_id),
    price_id bigint NOT NULL REFERENCES product_price (price_id),
    currency text NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    product_name text NOT NULL,
    unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    tax_rate numeric(5,4) NOT NULL CHECK (tax_rate >= 0 AND tax_rate < 1),
    PRIMARY KEY (order_id, line_no),
    FOREIGN KEY (order_id, currency) REFERENCES sales_order (order_id, currency)
);
-- Corrections after confirmation are new rows, never edits.
CREATE TABLE order_adjustment (
    adjustment_id bigint PRIMARY KEY,
    order_id bigint NOT NULL,
    currency text NOT NULL,
    amount numeric(12,2) NOT NULL CHECK (amount <> 0),
    reason text NOT NULL,
    FOREIGN KEY (order_id, currency) REFERENCES sales_order (order_id, currency)
);

-- Dated exchange-rate quotes: 1 unit of base_currency = rate units of quote_currency.
CREATE TABLE fx_quote (
    quote_id bigint NOT NULL UNIQUE,
    source text NOT NULL,
    base_currency text NOT NULL,
    quote_currency text NOT NULL,
    valid_at daterange NOT NULL CHECK (NOT lower_inf(valid_at)),
    rate numeric(18,8) NOT NULL CHECK (rate > 0),
    UNIQUE (quote_id, base_currency, quote_currency),
    CHECK (base_currency <> quote_currency),
    CONSTRAINT fx_quote_no_overlap
        PRIMARY KEY (source, base_currency, quote_currency, valid_at WITHOUT OVERLAPS)
);
-- A conversion copies the applied rate and keeps a reference to the quote it came from.
CREATE TABLE order_conversion (
    order_id bigint PRIMARY KEY,
    from_currency text NOT NULL,
    to_currency text NOT NULL,
    quote_id bigint NOT NULL,
    applied_rate numeric(18,8) NOT NULL CHECK (applied_rate > 0),
    source_amount numeric(12,2) NOT NULL,
    converted_amount numeric(12,2) GENERATED ALWAYS AS
        (round(source_amount * applied_rate, 2)) STORED,
    FOREIGN KEY (order_id, from_currency) REFERENCES sales_order (order_id, currency),
    FOREIGN KEY (quote_id, from_currency, to_currency)
        REFERENCES fx_quote (quote_id, base_currency, quote_currency)
);

-- A confirmed order and its lines are frozen.
CREATE FUNCTION guard_confirmed_order() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.state = 'confirmed' THEN
        RAISE EXCEPTION 'confirmed order % is immutable', OLD.order_id
            USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER sales_order_frozen
BEFORE UPDATE OR DELETE ON sales_order
FOR EACH ROW EXECUTE FUNCTION guard_confirmed_order();

CREATE FUNCTION guard_confirmed_lines() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_order_id bigint;
    v_state text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_order_id := NEW.order_id;
    ELSE
        v_order_id := OLD.order_id;
    END IF;
    -- FOR SHARE conflicts with the confirming UPDATE; FOR KEY SHARE would not.
    SELECT state INTO v_state FROM sales_order WHERE order_id = v_order_id FOR SHARE;
    IF v_state = 'confirmed'
       OR (TG_OP = 'UPDATE' AND NEW.order_id <> OLD.order_id) THEN
        RAISE EXCEPTION 'lines of confirmed order % are immutable', v_order_id
            USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER order_line_frozen
BEFORE INSERT OR UPDATE OR DELETE ON order_line
FOR EACH ROW EXECUTE FUNCTION guard_confirmed_lines();

-- Placement copies the price the customer was shown, verified under the product lock.
CREATE FUNCTION place_line(
    p_order_id bigint, p_line_no integer, p_product_id bigint,
    p_quantity integer, p_shown_price_id bigint, p_shown_amount numeric
) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE
    v_order sales_order%ROWTYPE;
    v_product product%ROWTYPE;
    v_price product_price%ROWTYPE;
BEGIN
    SELECT * INTO STRICT v_order FROM sales_order WHERE order_id = p_order_id;
    -- Schedule editors lock the product row FOR UPDATE before changing prices.
    SELECT * INTO STRICT v_product FROM product WHERE product_id = p_product_id FOR SHARE;
    SELECT * INTO v_price FROM product_price
    WHERE product_id = p_product_id
      AND currency = v_order.currency
      AND valid_at @> v_order.order_date;
    -- The schedule can be corrected in place, so compare the amount as well as the row.
    IF NOT FOUND OR v_price.price_id <> p_shown_price_id
       OR v_price.amount <> p_shown_amount THEN
        RAISE EXCEPTION 'shown price % (%) is not current for product % on %',
            p_shown_price_id, p_shown_amount, p_product_id, v_order.order_date
            USING ERRCODE = 'P0001', HINT = 'Show the customer the current price.';
    END IF;
    INSERT INTO order_line (order_id, line_no, product_id, price_id, currency, quantity,
                            product_name, unit_price, tax_rate)
    VALUES (p_order_id, p_line_no, p_product_id, v_price.price_id, v_price.currency,
            p_quantity, v_product.name, v_price.amount, v_product.tax_rate);
    RETURN v_price.amount;
END;
$$;

-- Confirmation captures the billing address and closes the edit path.
CREATE PROCEDURE confirm_order(p_order_id bigint)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT FROM order_line WHERE order_id = p_order_id) THEN
        RAISE EXCEPTION 'order % has no lines', p_order_id USING ERRCODE = '23514';
    END IF;
    UPDATE sales_order o
    SET state = 'confirmed', billing_address = c.billing_address, confirmed_at = now()
    FROM customer c
    WHERE o.order_id = p_order_id AND o.state = 'draft' AND c.customer_id = o.customer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order % is not a draft', p_order_id USING ERRCODE = '23514';
    END IF;
END;
$$;

-- Totals always carry their currency.
CREATE VIEW order_total AS
SELECT o.order_id, o.currency,
       coalesce((SELECT sum(l.quantity * l.unit_price) FROM order_line l
                 WHERE l.order_id = o.order_id), 0)
     + coalesce((SELECT sum(a.amount) FROM order_adjustment a
                 WHERE a.order_id = o.order_id), 0) AS net_amount
FROM sales_order o;

-- Data.
INSERT INTO customer VALUES (1, 'Torstrasse 1, 10119 Berlin');
INSERT INTO product VALUES (1, 'Espresso grinder', 0.1900), (2, 'Milk jug', 0.1900);
INSERT INTO product_price VALUES
    (101, 1, 'EUR', daterange('2026-01-01', NULL), 250.00),
    (201, 2, 'USD', daterange('2026-01-01', NULL), 30.00);
INSERT INTO sales_order (order_id, customer_id, currency, order_date) VALUES
    (1, 1, 'EUR', DATE '2026-02-20'),
    (2, 1, 'USD', DATE '2026-02-27');

-- Order 1: the customer was shown price 101.
SELECT place_line(1, 1, 1, 1, 101, 250.00) = 250.00 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
CALL confirm_order(1);

-- The sources change after the fact: rename, move, reprice from February 27.
UPDATE product SET name = 'Espresso grinder Pro', tax_rate = 0.0700 WHERE product_id = 1;
UPDATE customer SET billing_address = 'Jungfernstieg 7, 20354 Hamburg' WHERE customer_id = 1;
SELECT true AS locked FROM product WHERE product_id = 1 FOR UPDATE \gset
UPDATE product_price SET valid_at = daterange('2026-01-01', '2026-02-27')
WHERE price_id = 101;
INSERT INTO product_price VALUES (102, 1, 'EUR', daterange('2026-02-27', NULL), 270.00);

-- The captured fact keeps what was true; a join to the source shows today's values.
SELECT l.product_name = 'Espresso grinder' AND l.unit_price = 250.00
   AND l.tax_rate = 0.1900 AND o.billing_address = 'Torstrasse 1, 10119 Berlin'
   AND p.name = 'Espresso grinder Pro' AND c.billing_address LIKE '%Hamburg'
   AS valid
FROM order_line l
JOIN sales_order o USING (order_id)
JOIN product p USING (product_id)
JOIN customer c ON c.customer_id = o.customer_id
WHERE l.order_id = 1 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A dated lookup agrees only until someone corrects the schedule in place.
SELECT true AS locked FROM product WHERE product_id = 1 FOR UPDATE \gset
UPDATE product_price SET amount = 240.00 WHERE price_id = 101;
SELECT (SELECT pp.amount FROM product_price pp
        WHERE pp.product_id = 1 AND pp.currency = 'EUR'
          AND pp.valid_at @> DATE '2026-02-20') = 240.00
   AND (SELECT unit_price FROM order_line WHERE order_id = 1 AND line_no = 1) = 250.00
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- The kept reference finds the lines a correction affected.
SELECT count(*) = 1 AS valid
FROM order_line l JOIN product_price pp USING (price_id)
WHERE l.unit_price <> pp.amount \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Captured columns of a confirmed order cannot be edited.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE order_line SET unit_price = 240.00 WHERE order_id = 1 AND line_no = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM order_line WHERE order_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE sales_order SET billing_address = 'Jungfernstieg 7, 20354 Hamburg'
WHERE order_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT place_line(1, 2, 1, 1, 101, 240.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE sales_order SET state = 'draft' WHERE order_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM sales_order WHERE order_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- After the in-place correction, a customer shown 101 at 250.00 is rejected;
-- 101 at 240.00 is what the page now shows. A draft stays editable.
INSERT INTO sales_order (order_id, customer_id, currency, order_date) VALUES
    (4, 1, 'EUR', DATE '2026-02-20');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT place_line(4, 1, 1, 1, 101, 250.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT place_line(4, 1, 1, 1, 101, 240.00) = 240.00 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
UPDATE order_line SET quantity = 2 WHERE order_id = 4 AND line_no = 1;
SELECT (SELECT net_amount = 480.00 FROM order_total WHERE order_id = 4) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
DELETE FROM order_line WHERE order_id = 4;
DELETE FROM sales_order WHERE order_id = 4;
SELECT NOT EXISTS (SELECT FROM sales_order WHERE order_id = 4) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A correction is an explicit adjustment row.
INSERT INTO order_adjustment VALUES
    (1, 1, 'EUR', -10.00, 'Price list error corrected on 2026-03-02');
SELECT (SELECT net_amount = 240.00 FROM order_total WHERE order_id = 1)
   AND (SELECT unit_price = 250.00 FROM order_line WHERE order_id = 1)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Order 3 is dated after the price change: a stale shown price is rejected.
INSERT INTO sales_order (order_id, customer_id, currency, order_date) VALUES
    (3, 1, 'EUR', DATE '2026-02-27');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT place_line(3, 1, 1, 1, 101, 250.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT place_line(3, 1, 1, 1, 102, 270.00) = 270.00 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- Confirmation captures today's address; order 1 keeps the earlier one.
CALL confirm_order(3);
SELECT (SELECT billing_address LIKE '%Hamburg' FROM sales_order WHERE order_id = 3)
   AND (SELECT billing_address LIKE '%Berlin' FROM sales_order WHERE order_id = 1)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A line cannot carry a currency other than its order's.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO order_line VALUES (2, 1, 1, 102, 'EUR', 1, 'Espresso grinder Pro', 270.00, 0.0700);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Order 2 in USD, converted to the EUR reporting currency at a dated quote.
SELECT place_line(2, 1, 2, 2, 201, 30.00) = 30.00 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
CALL confirm_order(2);
INSERT INTO fx_quote VALUES
    (301, 'treasury', 'USD', 'EUR', daterange('2026-02-27', '2026-02-28'), 0.86000000),
    (302, 'treasury', 'USD', 'EUR', daterange('2026-02-28', '2026-03-01'), 0.85500000);

INSERT INTO order_conversion (order_id, from_currency, to_currency, quote_id,
                              applied_rate, source_amount)
SELECT o.order_id, o.currency, 'EUR', q.quote_id, q.rate, t.net_amount
FROM sales_order o
JOIN order_total t USING (order_id)
JOIN fx_quote q ON q.source = 'treasury' AND q.base_currency = o.currency
               AND q.quote_currency = 'EUR' AND q.valid_at @> o.order_date
WHERE o.order_id = 2;
SELECT quote_id = 301 AND converted_amount = 51.60 AS valid
FROM order_conversion WHERE order_id = 2 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A quote whose currencies do not match the order is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO order_conversion (order_id, from_currency, to_currency, quote_id,
                              applied_rate, source_amount)
VALUES (1, 'EUR', 'USD', 301, 0.86000000, 240.00);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A corrected quote does not change the conversion; the reference finds it.
UPDATE fx_quote SET rate = 0.87000000 WHERE quote_id = 301;
SELECT (SELECT converted_amount = 51.60 AND applied_rate = 0.86 FROM order_conversion
        WHERE order_id = 2)
   AND (SELECT count(*) = 1 FROM order_conversion c JOIN fx_quote q USING (quote_id)
        WHERE c.applied_rate <> q.rate)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Totals are reported per currency, and in EUR only through captured conversions.
SELECT count(*) = 2 AND bool_and(
           (currency = 'EUR' AND total = 510.00) OR (currency = 'USD' AND total = 60.00))
   AS valid
FROM (SELECT currency, sum(net_amount) AS total FROM order_total
      GROUP BY currency) s \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT sum(eur) = 561.60 AS valid
FROM (
    SELECT net_amount AS eur FROM order_total WHERE currency = 'EUR'
    UNION ALL
    SELECT converted_amount FROM order_conversion WHERE to_currency = 'EUR'
) s \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Insert-only facts can rely on privileges alone: the application role cannot update.
CREATE ROLE captured_value_app NOLOGIN;
GRANT USAGE ON SCHEMA captured_example TO captured_value_app;
GRANT SELECT, INSERT ON order_conversion, order_adjustment TO captured_value_app;
SET LOCAL ROLE captured_value_app;
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE order_conversion SET applied_rate = 0.87000000 WHERE order_id = 2;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
RESET ROLE;
SELECT :'rejected_state' = '42501' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
