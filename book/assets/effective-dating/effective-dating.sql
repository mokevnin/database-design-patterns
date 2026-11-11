-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f effective-dating.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA effective_example;
CREATE TABLE effective_example.product (
    product_id bigint PRIMARY KEY
);
CREATE TABLE effective_example.price (
    product_id bigint REFERENCES effective_example.product (product_id),
    valid_at daterange NOT NULL CHECK (NOT lower_inf(valid_at)),
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    CONSTRAINT price_no_overlap PRIMARY KEY (product_id, valid_at WITHOUT OVERLAPS)
);

INSERT INTO effective_example.product VALUES (1);
INSERT INTO effective_example.price VALUES
    (1, daterange('2026-01-01', '2026-02-01', '[)'), 100),
    (1, daterange('2026-02-01', NULL, '[)'), 110);
BEGIN;
SELECT product_id FROM effective_example.product WHERE product_id = 1 FOR UPDATE;
UPDATE effective_example.price
SET valid_at = daterange('2026-02-01', '2026-03-01', '[)')
WHERE product_id = 1 AND valid_at = daterange('2026-02-01', NULL, '[)');
INSERT INTO effective_example.price VALUES
    (1, daterange('2026-03-01', NULL, '[)'), 120);
COMMIT;
SELECT amount FROM effective_example.price
WHERE product_id = 1 AND valid_at @> DATE '2026-03-01';

BEGIN;
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO effective_example.price VALUES
    (1, daterange('2026-02-15', '2026-03-15', '[)'), 99);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

CREATE TABLE effective_example.price_commitment (
    commitment_id bigint PRIMARY KEY,
    product_id bigint NOT NULL,
    covered_at daterange NOT NULL,
    CONSTRAINT commitment_coverage FOREIGN KEY (product_id, PERIOD covered_at)
        REFERENCES effective_example.price (product_id, PERIOD valid_at)
);
INSERT INTO effective_example.price_commitment VALUES
    (1, 1, daterange('2026-01-15', '2026-03-15', '[)'));

SELECT (SELECT count(*) = 3 FROM effective_example.price)
    AND (SELECT amount = 120 FROM effective_example.price
         WHERE product_id = 1 AND valid_at @> DATE '2026-03-01') AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
SAVEPOINT coverage_gap;
\set ON_ERROR_STOP off
DELETE FROM effective_example.price
WHERE product_id = 1 AND valid_at @> DATE '2026-02-15';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT coverage_gap;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

ROLLBACK;
DROP SCHEMA effective_example CASCADE;
