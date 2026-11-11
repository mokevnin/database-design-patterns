-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f soft-delete.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA soft_example;
CREATE TABLE soft_example.customer (
    customer_id bigint PRIMARY KEY,
    email text NOT NULL,
    deleted_at timestamptz
);
CREATE UNIQUE INDEX customer_live_email_key ON soft_example.customer (email)
WHERE deleted_at IS NULL;
CREATE TABLE soft_example.invoice (
    invoice_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES soft_example.customer (customer_id)
);
CREATE VIEW soft_example.live_customer AS
SELECT customer_id, email FROM soft_example.customer WHERE deleted_at IS NULL;

INSERT INTO soft_example.customer VALUES (1, 'alex@example.com', NULL);
INSERT INTO soft_example.invoice VALUES (10, 1);
UPDATE soft_example.customer SET deleted_at = clock_timestamp()
WHERE customer_id = 1 AND deleted_at IS NULL;
INSERT INTO soft_example.customer VALUES (2, 'alex@example.com', NULL);
SELECT customer_id FROM soft_example.live_customer;
SELECT i.invoice_id, c.customer_id, c.deleted_at IS NOT NULL AS deleted
FROM soft_example.invoice AS i
JOIN soft_example.customer AS c USING (customer_id);

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE soft_example.customer SET deleted_at = NULL WHERE customer_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

CREATE TABLE soft_example.deleted_customer (
    archive_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id bigint NOT NULL,
    archived_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    data jsonb NOT NULL
);
WITH removed AS (
    DELETE FROM soft_example.customer WHERE customer_id = 2 RETURNING *
)
INSERT INTO soft_example.deleted_customer (customer_id, data)
SELECT customer_id, to_jsonb(removed) FROM removed;
UPDATE soft_example.customer SET deleted_at = NULL WHERE customer_id = 1;

SELECT (SELECT count(*) = 1 FROM soft_example.deleted_customer)
    AND (SELECT customer_id = 1 FROM soft_example.live_customer)
    AND (SELECT count(*) = 1 FROM soft_example.invoice) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
SAVEPOINT physical_delete;
\set ON_ERROR_STOP off
DELETE FROM soft_example.customer WHERE customer_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT physical_delete;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

ROLLBACK;
