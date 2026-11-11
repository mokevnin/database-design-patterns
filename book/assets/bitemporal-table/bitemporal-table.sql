-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f bitemporal-table.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA bitemporal_example;
CREATE TABLE bitemporal_example.product (
    product_id bigint PRIMARY KEY
);
CREATE TABLE bitemporal_example.price_fact (
    version_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id bigint NOT NULL REFERENCES bitemporal_example.product (product_id),
    valid_at daterange NOT NULL CHECK (NOT isempty(valid_at) AND NOT lower_inf(valid_at)),
    known_at tstzrange NOT NULL CHECK (
        NOT isempty(known_at) AND NOT lower_inf(known_at)
        AND lower_inc(known_at) AND NOT upper_inc(known_at)
    ),
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    CONSTRAINT price_fact_no_overlap EXCLUDE USING gist
        (product_id WITH =, valid_at WITH &&, known_at WITH &&)
);
CREATE FUNCTION bitemporal_example.correct_price(
    p_product_id bigint, p_from date, p_amount numeric
) RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    old_fact bitemporal_example.price_fact%ROWTYPE;
    boundary timestamptz;
BEGIN
    PERFORM 1 FROM bitemporal_example.product
    WHERE product_id = p_product_id FOR UPDATE;
    SELECT * INTO STRICT old_fact FROM bitemporal_example.price_fact
    WHERE product_id = p_product_id AND upper_inf(known_at)
      AND valid_at @> p_from;
    SELECT greatest(clock_timestamp(),
                    max(lower(known_at)) + interval '1 microsecond')
    INTO boundary FROM bitemporal_example.price_fact
    WHERE product_id = p_product_id;
    UPDATE bitemporal_example.price_fact
    SET known_at = tstzrange(lower(known_at), boundary, '[)')
    WHERE version_id = old_fact.version_id;
    IF p_from > lower(old_fact.valid_at) THEN
        INSERT INTO bitemporal_example.price_fact
            (product_id, valid_at, known_at, amount)
        VALUES (p_product_id, daterange(lower(old_fact.valid_at), p_from, '[)'),
                tstzrange(boundary, NULL, '[)'), old_fact.amount);
    END IF;
    INSERT INTO bitemporal_example.price_fact
        (product_id, valid_at, known_at, amount)
    VALUES (p_product_id, daterange(p_from, upper(old_fact.valid_at), '[)'),
            tstzrange(boundary, NULL, '[)'), p_amount);
    RETURN boundary;
END;
$$;
REVOKE ALL ON FUNCTION bitemporal_example.correct_price(bigint, date, numeric)
    FROM PUBLIC;

INSERT INTO bitemporal_example.product VALUES (1);
-- Trusted import baseline: this example's knowledge begins on January 10.
INSERT INTO bitemporal_example.price_fact (product_id, valid_at, known_at, amount)
VALUES (1, daterange('2026-01-01', '2026-04-01', '[)'),
        tstzrange('2026-01-10 00:00+00', NULL, '[)'), 100);
SELECT bitemporal_example.correct_price(1, DATE '2026-02-15', 120);
SELECT amount FROM bitemporal_example.price_fact
WHERE product_id = 1 AND valid_at @> DATE '2026-02-20'
  AND known_at @> TIMESTAMPTZ '2026-03-01 00:00+00';
SELECT amount FROM bitemporal_example.price_fact
WHERE product_id = 1 AND valid_at @> DATE '2026-02-20'
  AND upper_inf(known_at);

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO bitemporal_example.price_fact (product_id, valid_at, known_at, amount)
VALUES (1, daterange('2026-02-20', '2026-03-01', '[)'),
        tstzrange('2026-01-10 00:00+00', NULL, '[)'), 90);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

SELECT (SELECT count(*) = 3 FROM bitemporal_example.price_fact)
    AND (SELECT amount = 100 FROM bitemporal_example.price_fact
         WHERE product_id = 1 AND valid_at @> DATE '2026-02-20'
           AND known_at @> TIMESTAMPTZ '2026-03-01 00:00+00')
    AND (SELECT amount = 120 FROM bitemporal_example.price_fact
         WHERE product_id = 1 AND valid_at @> DATE '2026-02-20'
           AND upper_inf(known_at)) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
SAVEPOINT failed_correction;
\set ON_ERROR_STOP off
SELECT bitemporal_example.correct_price(1, DATE '2026-02-20', -1);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT failed_correction;
SELECT :'rejected_state' = '23514'
    AND (SELECT count(*) = 3 FROM bitemporal_example.price_fact) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif

ROLLBACK;
