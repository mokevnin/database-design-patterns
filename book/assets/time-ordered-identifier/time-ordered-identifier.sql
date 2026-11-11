-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f time-ordered-identifier.sql in an empty database.
-- The duplicate-ID error is intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE event_record (
    event_id uuid PRIMARY KEY DEFAULT uuidv7(),
    source_reference text NOT NULL UNIQUE,
    payload text NOT NULL,
    CONSTRAINT event_id_v7 CHECK ((uuid_extract_version(event_id) = 7) IS TRUE)
);
CREATE TABLE event_delivery (
    event_id uuid NOT NULL REFERENCES event_record (event_id),
    destination text NOT NULL,
    PRIMARY KEY (event_id, destination)
);

INSERT INTO event_record (source_reference, payload)
VALUES ('import:104', 'created') RETURNING event_id;
-- Application-generated UUIDv7; fixed here so this example is reproducible.
INSERT INTO event_record (event_id, source_reference, payload)
VALUES ('019535d9-3df7-79fb-b466-fa907fa17f9e', 'import:105', 'created');
INSERT INTO event_delivery
VALUES ('019535d9-3df7-79fb-b466-fa907fa17f9e', 'billing');
UPDATE event_record SET payload = 'validated'
WHERE source_reference = 'import:105';
SELECT source_reference, payload FROM event_record
WHERE event_id = '019535d9-3df7-79fb-b466-fa907fa17f9e';
SELECT uuid_extract_version(event_id) AS version,
       uuid_extract_timestamp(event_id) AT TIME ZONE 'UTC' AS generated_at
FROM event_record WHERE source_reference = 'import:105';
-- version = 7, generated_at = 2025-02-24 02:46:24.503.
SELECT source_reference FROM event_record ORDER BY event_id;
-- A key order, not a commit-order feed.

SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO event_record (event_id, source_reference, payload)
VALUES ('019535d9-3df7-79fb-b466-fa907fa17f9e', 'import:106', 'duplicate');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

ROLLBACK;
