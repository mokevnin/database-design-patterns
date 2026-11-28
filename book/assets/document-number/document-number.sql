-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f document-number.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
-- Two-session waits are described in the chapter; this script replays their outcomes in one session.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA doc_example;

CREATE TABLE doc_example.company (
    company_id bigint PRIMARY KEY,
    invoice_prefix text NOT NULL CHECK (invoice_prefix ~ '^[A-Z]{2,5}$')
);

-- One counter row per numbering scope: company and fiscal year.
CREATE TABLE doc_example.invoice_counter (
    company_id bigint NOT NULL REFERENCES doc_example.company (company_id),
    fiscal_year integer NOT NULL CHECK (fiscal_year BETWEEN 2000 AND 9999),
    last_number integer NOT NULL CHECK (last_number >= 0),
    PRIMARY KEY (company_id, fiscal_year)
);

-- The invoice keeps its own surrogate key; the number is a unique attribute within its scope.
CREATE TABLE doc_example.invoice (
    invoice_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id bigint NOT NULL REFERENCES doc_example.company (company_id),
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'issued', 'void')),
    customer_name text NOT NULL,
    total numeric(12, 2) NOT NULL,
    issued_on date,
    fiscal_year integer,
    invoice_number integer CHECK (invoice_number > 0),
    voided_at timestamptz,
    void_reason text,
    CONSTRAINT invoice_number_key UNIQUE (company_id, fiscal_year, invoice_number),
    CONSTRAINT invoice_numbered_when_issued CHECK (
        (status = 'draft' AND issued_on IS NULL AND fiscal_year IS NULL
            AND invoice_number IS NULL)
        OR (status <> 'draft' AND issued_on IS NOT NULL AND fiscal_year IS NOT NULL
            AND invoice_number IS NOT NULL
            AND fiscal_year = extract(year FROM issued_on))
    ),
    CONSTRAINT invoice_void_explained CHECK (
        (status = 'void') = (voided_at IS NOT NULL AND void_reason IS NOT NULL)
    )
);

-- Issued invoices are voided, never deleted or restored, and their number never changes.
CREATE FUNCTION doc_example.keep_issued_invoice() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status <> 'draft' AND (
        TG_OP = 'DELETE'
        OR NEW.status = 'draft'
        OR (OLD.status = 'void' AND NEW.status <> 'void')
        OR NEW.invoice_number IS DISTINCT FROM OLD.invoice_number
        OR NEW.fiscal_year IS DISTINCT FROM OLD.fiscal_year
        OR NEW.company_id IS DISTINCT FROM OLD.company_id
    ) THEN
        RAISE EXCEPTION 'invoice % is % and keeps its number', OLD.invoice_id, OLD.status;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER invoice_keep_issued
BEFORE UPDATE OR DELETE ON doc_example.invoice
FOR EACH ROW EXECUTE FUNCTION doc_example.keep_issued_invoice();

-- The prefix and padding are presentation, rendered from the scope and the integer.
CREATE VIEW doc_example.invoice_register AS
SELECT i.invoice_id, i.company_id, i.fiscal_year, i.invoice_number, i.status,
       format('%s-%s-%s', c.invoice_prefix, i.fiscal_year,
              lpad(i.invoice_number::text, greatest(6, length(i.invoice_number::text)), '0'))
           AS display_number
FROM doc_example.invoice AS i
JOIN doc_example.company AS c USING (company_id)
WHERE i.status <> 'draft';

INSERT INTO doc_example.company VALUES (1, 'INV'), (2, 'RE');
-- Opening the year creates the scope's counter.
INSERT INTO doc_example.invoice_counter VALUES (1, 2026, 0), (2, 2026, 0);
INSERT INTO doc_example.invoice (company_id, customer_name, total) VALUES
    (1, 'Northwind', 120.00),
    (1, 'Contoso', 80.00),
    (2, 'Fabrikam', 50.00),
    (1, 'Tailspin', 10.00);

-- Issue a draft: increment the scope's counter and assign the number in one statement.
WITH allocated AS (
    UPDATE doc_example.invoice_counter
    SET last_number = last_number + 1
    WHERE company_id = 1 AND fiscal_year = 2026
    RETURNING last_number
)
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2026-03-02', fiscal_year = 2026,
    invoice_number = (SELECT last_number FROM allocated)
WHERE invoice_id = 1 AND status = 'draft'
RETURNING invoice_number AS first_number \gset
SELECT :first_number = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

WITH allocated AS (
    UPDATE doc_example.invoice_counter
    SET last_number = last_number + 1
    WHERE company_id = 1 AND fiscal_year = 2026
    RETURNING last_number
)
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2026-03-05', fiscal_year = 2026,
    invoice_number = (SELECT last_number FROM allocated)
WHERE invoice_id = 2 AND status = 'draft';

-- Another company has its own scope and starts at 1.
WITH allocated AS (
    UPDATE doc_example.invoice_counter
    SET last_number = last_number + 1
    WHERE company_id = 2 AND fiscal_year = 2026
    RETURNING last_number
)
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2026-03-05', fiscal_year = 2026,
    invoice_number = (SELECT last_number FROM allocated)
WHERE invoice_id = 3 AND status = 'draft';
SELECT (SELECT array_agg(display_number ORDER BY invoice_id) FROM doc_example.invoice_register)
       = ARRAY['INV-2026-000001', 'INV-2026-000002', 'RE-2026-000001'] AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A rolled-back issue also rolls back the counter: the next issue reuses the number.
SAVEPOINT failed_issue;
UPDATE doc_example.invoice_counter SET last_number = last_number + 1
WHERE company_id = 1 AND fiscal_year = 2026
RETURNING last_number AS lost_number \gset
ROLLBACK TO SAVEPOINT failed_issue;
UPDATE doc_example.invoice_counter SET last_number = last_number + 1
WHERE company_id = 1 AND fiscal_year = 2026
RETURNING last_number AS kept_number \gset
SELECT :lost_number = 3 AND :kept_number = 3 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2026-03-09', fiscal_year = 2026,
    invoice_number = :kept_number
WHERE invoice_id = 4;

-- Issuing an invoice that is no longer a draft updates no invoice row,
-- but the counter was incremented: the caller must roll back.
SAVEPOINT repeated_issue;
WITH allocated AS (
    UPDATE doc_example.invoice_counter
    SET last_number = last_number + 1
    WHERE company_id = 1 AND fiscal_year = 2026
    RETURNING last_number
)
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2026-03-02', fiscal_year = 2026,
    invoice_number = (SELECT last_number FROM allocated)
WHERE invoice_id = 1 AND status = 'draft';
SELECT :ROW_COUNT = 0
   AND (SELECT last_number FROM doc_example.invoice_counter
        WHERE company_id = 1 AND fiscal_year = 2026) = 4 AS valid \gset
ROLLBACK TO SAVEPOINT repeated_issue;
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Numbers are dense per scope: count, maximum and counter agree.
SELECT bool_and(n.issued = c.last_number AND n.top = c.last_number) AS valid
FROM doc_example.invoice_counter AS c
JOIN (SELECT company_id, fiscal_year, count(*) AS issued, max(invoice_number) AS top
      FROM doc_example.invoice WHERE status <> 'draft'
      GROUP BY company_id, fiscal_year) AS n USING (company_id, fiscal_year) \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A sequence is not gapless: a rolled-back nextval is not returned.
CREATE SEQUENCE doc_example.invoice_1_2026_seq;
SAVEPOINT failed_issue;
SELECT nextval('doc_example.invoice_1_2026_seq') AS rolled_back_value \gset
ROLLBACK TO SAVEPOINT failed_issue;
SELECT nextval('doc_example.invoice_1_2026_seq') AS next_value \gset
SELECT :rolled_back_value = 1 AND :next_value = 2 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- INSERT ... ON CONFLICT DO NOTHING consumes a value even without an abort.
CREATE TABLE doc_example.ticket (
    ticket_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_key text NOT NULL UNIQUE
);
INSERT INTO doc_example.ticket (request_key) VALUES ('a');
INSERT INTO doc_example.ticket (request_key) VALUES ('a') ON CONFLICT DO NOTHING;
INSERT INTO doc_example.ticket (request_key) VALUES ('b');
SELECT (SELECT array_agg(ticket_id ORDER BY ticket_id) FROM doc_example.ticket)
       = ARRAY[1, 3] AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Cached values that a session never uses are lost; DISCARD SEQUENCES drops them like a session end.
CREATE SEQUENCE doc_example.cached_seq CACHE 20;
SELECT nextval('doc_example.cached_seq') AS cached_first \gset
DISCARD SEQUENCES;
SELECT nextval('doc_example.cached_seq') AS cached_next \gset
SELECT :cached_first = 1 AND :cached_next = 21 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Year rollover: the first invoice of 2027 opens its scope lazily and gets number 1.
INSERT INTO doc_example.invoice (company_id, customer_name, total)
VALUES (1, 'Northwind', 300.00) RETURNING invoice_id AS jan_draft \gset
INSERT INTO doc_example.invoice_counter AS c (company_id, fiscal_year, last_number)
VALUES (1, 2027, 1)
ON CONFLICT (company_id, fiscal_year)
DO UPDATE SET last_number = c.last_number + 1
RETURNING last_number AS jan_number \gset
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2027-01-04', fiscal_year = 2027,
    invoice_number = :jan_number
WHERE invoice_id = :jan_draft;
SELECT (SELECT display_number FROM doc_example.invoice_register
        WHERE invoice_id = :jan_draft) = 'INV-2027-000001' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Padding is a minimum width, never a truncation.
SELECT format('%s-%s-%s', 'INV', 2026,
              lpad('1234567', greatest(6, length('1234567')), '0')) = 'INV-2026-1234567'
   AND lpad('1234567', 6, '0') = '123456' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A scope that was never opened makes the allocation return no row,
-- and the issued-invoice check rejects the missing number.
INSERT INTO doc_example.invoice (company_id, customer_name, total)
VALUES (2, 'Fabrikam', 70.00) RETURNING invoice_id AS unopened_draft \gset
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
WITH allocated AS (
    UPDATE doc_example.invoice_counter
    SET last_number = last_number + 1
    WHERE company_id = 2 AND fiscal_year = 2027
    RETURNING last_number
)
UPDATE doc_example.invoice
SET status = 'issued', issued_on = DATE '2027-01-05', fiscal_year = 2027,
    invoice_number = (SELECT last_number FROM allocated)
WHERE invoice_id = :unopened_draft AND status = 'draft';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Voiding keeps the number in the register.
UPDATE doc_example.invoice
SET status = 'void', voided_at = now(), void_reason = 'Wrong customer'
WHERE invoice_id = 2;
SELECT (SELECT display_number || ' ' || status FROM doc_example.invoice_register
        WHERE invoice_id = 2) = 'INV-2026-000002 void' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A voided number cannot be issued again.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO doc_example.invoice
    (company_id, status, customer_name, total, issued_on, fiscal_year, invoice_number)
VALUES (1, 'issued', 'Contoso', 80.00, DATE '2026-03-10', 2026, 2);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An issued invoice without an issue date or year is rejected; it would escape the unique key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO doc_example.invoice
    (company_id, status, customer_name, total, invoice_number)
VALUES (1, 'issued', 'Contoso', 80.00, 2);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An issued invoice cannot be renumbered or returned to draft.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE doc_example.invoice SET invoice_number = 9 WHERE invoice_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE doc_example.invoice
SET status = 'draft', issued_on = NULL, fiscal_year = NULL, invoice_number = NULL
WHERE invoice_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A voided invoice cannot be reissued.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE doc_example.invoice
SET status = 'issued', voided_at = NULL, void_reason = NULL
WHERE invoice_id = 2;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An issued or voided invoice cannot be deleted; a draft can.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
DELETE FROM doc_example.invoice WHERE invoice_id = 2;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
DELETE FROM doc_example.invoice WHERE invoice_id = :unopened_draft;

-- Issue numbers per project allocated with max(number) + 1.
CREATE TABLE doc_example.issue (
    issue_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id bigint NOT NULL,
    issue_number integer NOT NULL CHECK (issue_number > 0),
    title text NOT NULL,
    CONSTRAINT issue_number_key UNIQUE (project_id, issue_number)
);
INSERT INTO doc_example.issue (project_id, issue_number, title) VALUES (7, 1, 'Crash on login');

-- Replay of two sessions that both read the maximum before either inserts.
SELECT coalesce(max(issue_number), 0) + 1 AS a_number
FROM doc_example.issue WHERE project_id = 7 \gset
SELECT coalesce(max(issue_number), 0) + 1 AS b_number
FROM doc_example.issue WHERE project_id = 7 \gset
INSERT INTO doc_example.issue (project_id, issue_number, title)
VALUES (7, :a_number, 'Slow search');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO doc_example.issue (project_id, issue_number, title)
VALUES (7, :b_number, 'Typo in footer');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :a_number = 2 AND :b_number = 2 AND :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The retry recomputes the maximum and succeeds.
INSERT INTO doc_example.issue (project_id, issue_number, title)
SELECT 7, coalesce(max(issue_number), 0) + 1, 'Typo in footer'
FROM doc_example.issue WHERE project_id = 7
RETURNING issue_number AS retried_number \gset
SELECT :retried_number = 3 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Deleting the newest issue makes max(number) + 1 hand out its number again.
DELETE FROM doc_example.issue WHERE project_id = 7 AND issue_number = 3;
SELECT coalesce(max(issue_number), 0) + 1 = 3 AS valid
FROM doc_example.issue WHERE project_id = 7 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
