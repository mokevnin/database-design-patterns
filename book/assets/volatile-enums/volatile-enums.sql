-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f volatile-enums.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA volatile_enums_lab;
SET search_path TO volatile_enums_lab, public;

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

CREATE TYPE channel_kind AS ENUM ('web', 'store');
CREATE TABLE sale_old (sale_id bigint PRIMARY KEY, channel channel_kind NOT NULL);
INSERT INTO sale_old VALUES (1, 'web'), (2, 'store');

SELECT pg_temp.expect_error($operation$INSERT INTO sale_old VALUES (3, 'partner');$operation$, '22P02', 'invalid input value for enum channel_kind: "partner"');

CREATE TABLE sales_channel (
    code text PRIMARY KEY,
    label text NOT NULL,
    is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE sale (
    sale_id bigint PRIMARY KEY,
    channel_code text NOT NULL,
    CONSTRAINT sale_channel_fk FOREIGN KEY (channel_code) REFERENCES sales_channel (code)
);
CREATE INDEX sale_channel_idx ON sale (channel_code);
BEGIN;
LOCK TABLE sale_old IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO sales_channel (code, label)
SELECT DISTINCT channel::text, initcap(channel::text) FROM sale_old;
INSERT INTO sale SELECT sale_id, channel::text FROM sale_old;
COMMIT;
BEGIN;
INSERT INTO sales_channel (code, label) VALUES ('partner', 'Partner sales');
INSERT INTO sale VALUES (3, 'partner');
COMMIT;
UPDATE sales_channel SET is_active = false WHERE code = 'store';
SELECT code, label FROM sales_channel WHERE is_active ORDER BY code;
SELECT s.sale_id, c.label, c.is_active FROM sale AS s
JOIN sales_channel AS c ON c.code = s.channel_code ORDER BY s.sale_id;

SELECT pg_temp.expect_error($operation$INSERT INTO sale VALUES (4, 'unknown');$operation$, '23503', 'insert or update on table "sale" violates foreign key constraint "sale_channel_fk"');

SELECT pg_temp.expect_error($operation$DELETE FROM sales_channel WHERE code = 'store';$operation$, '23503', 'update or delete on table "sales_channel" violates foreign key constraint "sale_channel_fk" on table "sale"');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 3 FROM sale);
    ASSERT (SELECT count(*) = 2 FROM sales_channel WHERE is_active);
END $$;
