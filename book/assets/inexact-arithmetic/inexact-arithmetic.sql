-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f inexact-arithmetic.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA inexact_arithmetic_lab;
SET search_path TO inexact_arithmetic_lab, public;

CREATE OR REPLACE FUNCTION pg_temp.expect_error(command text, expected_state text, expected_message text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual_state text;
    actual_message text;
BEGIN
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE,
            actual_message = MESSAGE_TEXT;
    END;
    IF actual_state IS DISTINCT FROM expected_state
       OR actual_message IS DISTINCT FROM expected_message THEN
        RAISE EXCEPTION 'Expected %: %, got %: %', expected_state,
            expected_message, actual_state, actual_message;
    END IF;
    RAISE NOTICE 'Expected %: %', actual_state, actual_message;
END;
$$;

CREATE TABLE invoice (
    invoice_id bigint PRIMARY KEY,
    currency text NOT NULL CHECK (currency = 'USD')
);
CREATE TABLE invoice_line_old (
    invoice_id bigint NOT NULL REFERENCES invoice (invoice_id),
    line_number integer NOT NULL,
    amount double precision NOT NULL,
    PRIMARY KEY (invoice_id, line_number)
);
INSERT INTO invoice VALUES (1, 'USD');
INSERT INTO invoice_line_old VALUES (1, 1, 0.1), (1, 2, 0.2);
SELECT sum(amount) AS total, sum(amount) = 0.3::double precision AS equals_expected
FROM invoice_line_old WHERE invoice_id = 1;

CREATE TABLE invoice_line (
    invoice_id bigint NOT NULL REFERENCES invoice (invoice_id),
    line_number integer NOT NULL,
    amount numeric NOT NULL,
    PRIMARY KEY (invoice_id, line_number),
    CONSTRAINT invoice_line_finite CHECK (
        amount > '-Infinity'::numeric AND amount < 'Infinity'::numeric
    ),
    CONSTRAINT invoice_line_scale CHECK (amount = round(amount, 2))
);
CREATE TABLE line_conversion (
    invoice_id bigint NOT NULL,
    line_number integer NOT NULL,
    old_amount double precision NOT NULL,
    proposed_amount numeric NOT NULL,
    approved boolean NOT NULL DEFAULT false,
    PRIMARY KEY (invoice_id, line_number)
);
BEGIN;
LOCK TABLE invoice_line_old IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO line_conversion (invoice_id, line_number, old_amount, proposed_amount)
SELECT invoice_id, line_number, amount, round(amount::numeric, 2) FROM invoice_line_old;
-- These two approvals stand for a review against the original decimal amounts in this lab.
UPDATE line_conversion SET approved = true
WHERE invoice_id = 1 AND ((line_number = 1 AND proposed_amount = 0.10)
    OR (line_number = 2 AND proposed_amount = 0.20));
INSERT INTO invoice_line
SELECT invoice_id, line_number, proposed_amount FROM line_conversion WHERE approved;
COMMIT;
SELECT sum(amount) AS total, sum(amount) = 0.30 AS equals_expected
FROM invoice_line WHERE invoice_id = 1;

SELECT pg_temp.expect_error($operation$INSERT INTO invoice_line VALUES (1, 3, 1.005);$operation$, '23514', 'new row for relation "invoice_line" violates check constraint "invoice_line_scale"');

SELECT pg_temp.expect_error($operation$INSERT INTO invoice_line VALUES (1, 3, 'NaN');$operation$, '23514', 'new row for relation "invoice_line" violates check constraint "invoice_line_finite"');

SELECT 1.005::numeric(10, 2) AS amount;
SELECT round(0.005::numeric, 2) + round(0.005::numeric, 2) AS round_each,
       round(0.005::numeric + 0.005::numeric, 2) AS round_total;
SELECT 10 / 3 AS whole_cents, 10 % 3 AS remaining_cents;

DO $$ BEGIN
    ASSERT (SELECT sum(amount) = 0.30 FROM invoice_line);
    ASSERT (SELECT sum(amount) <> 0.3::double precision FROM invoice_line_old);
    ASSERT (SELECT count(*) = 2 FROM line_conversion WHERE approved);
    ASSERT 1.005::numeric(10, 2) = 1.01;
END $$;
