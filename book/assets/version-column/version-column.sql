-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f version-column.sql in a disposable database.
-- Expected errors are isolated and their SQLSTATEs checked; all other errors stop execution.
\set ON_ERROR_STOP on
CREATE SCHEMA version_column_lab;
SET search_path = version_column_lab, public;

CREATE TABLE document (
    document_id bigint PRIMARY KEY,
    title text NOT NULL,
    version bigint NOT NULL DEFAULT 0,
    CONSTRAINT document_version_nonnegative CHECK (version >= 0)
);
CREATE TABLE document_section (
    section_id bigint PRIMARY KEY,
    document_id bigint NOT NULL REFERENCES document (document_id),
    body text NOT NULL
);
CREATE INDEX document_section_owner_idx ON document_section (document_id);
INSERT INTO document VALUES (1, 'Checklist', 0);
INSERT INTO document_section VALUES (10, 1, 'Review draft');
SELECT document_id, title, version FROM document WHERE document_id = 1;
UPDATE document SET title = 'Launch checklist', version = version + 1
WHERE document_id = 1 AND version = 0
RETURNING version;
UPDATE document SET title = 'Release checklist', version = version + 1
WHERE document_id = 1 AND version = 0
RETURNING version;

BEGIN;
UPDATE document SET version = version + 1
WHERE document_id = 1 AND version = 1
RETURNING version;
UPDATE document_section SET body = 'Review final draft'
WHERE document_id = 1 AND section_id = 10;
COMMIT;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
-- Expected SQLSTATE 23514.
UPDATE document SET version = -1 WHERE document_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

DO $$ BEGIN IF NOT ((SELECT title = 'Launch checklist' AND version = 2 FROM document WHERE document_id = 1)) THEN RAISE EXCEPTION 'version winner or aggregate token incorrect'; END IF; END $$;
DO $$ BEGIN IF NOT ((SELECT body = 'Review final draft' FROM document_section WHERE section_id = 10)) THEN RAISE EXCEPTION 'section edit missing'; END IF; END $$;

RESET search_path;
DROP SCHEMA version_column_lab CASCADE;
