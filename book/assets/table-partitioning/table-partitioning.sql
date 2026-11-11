-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f table-partitioning.sql in an empty database.
-- Intentional errors are checked by SQLSTATE; unexpected failures stop the script.
-- Creates the isolated table_partitioning_example schema and leaves it for inspection.
\set ON_ERROR_STOP on
CREATE SCHEMA table_partitioning_example;
SET search_path = table_partitioning_example, public;

CREATE TABLE account (
    account_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE activity_event (
    event_day date NOT NULL,
    event_id bigint NOT NULL,
    account_id bigint NOT NULL REFERENCES account (account_id),
    event_kind text NOT NULL,
    PRIMARY KEY (event_day, event_id)
) PARTITION BY RANGE (event_day);
CREATE TABLE activity_event_2026_11 PARTITION OF activity_event
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE activity_event_2026_12 PARTITION OF activity_event
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
CREATE INDEX activity_event_account_day_idx
    ON activity_event (account_id, event_day);
INSERT INTO account VALUES (1, 'Harbor');
INSERT INTO activity_event VALUES
    ('2026-11-30', 101, 1, 'login'),
    ('2026-12-01', 101, 1, 'login');
SELECT tableoid::regclass AS physical_table, event_day, event_id
FROM activity_event ORDER BY event_day;

SELECT (SELECT array_agg(tableoid::regclass::text ORDER BY event_day) = ARRAY['activity_event_2026_11', 'activity_event_2026_12'] FROM activity_event) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


EXPLAIN (COSTS OFF)
SELECT event_id, event_kind FROM activity_event
WHERE account_id = 1
  AND event_day >= DATE '2026-12-01'
  AND event_day < DATE '2027-01-01';
UPDATE activity_event SET event_kind = 'session_started'
WHERE event_day = DATE '2026-12-01' AND event_id = 101;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO activity_event VALUES ('2027-01-01', 102, 1, 'login');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '23514') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;


BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO activity_event VALUES ('2026-12-01', 101, 1, 'duplicate');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '23505') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;


BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
ALTER TABLE activity_event ADD UNIQUE (event_id);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '0A000') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;


CREATE TABLE activity_event_2027_01 PARTITION OF activity_event
    FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
ALTER TABLE activity_event
    DETACH PARTITION activity_event_2026_11 CONCURRENTLY;
SELECT count(*) FROM activity_event;
SELECT count(*) FROM activity_event_2026_11;

SELECT (SELECT (SELECT count(*) FROM activity_event) = 1 AND (SELECT count(*) FROM activity_event_2026_11) = 1) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


ALTER TABLE activity_event ATTACH PARTITION activity_event_2026_11
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');

SELECT (SELECT count(*) = 2 FROM activity_event) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO activity_event VALUES ('2026-12-02', 103, 99, 'login');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '23503') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;

