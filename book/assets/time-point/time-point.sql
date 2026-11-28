-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f time-point.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA time_example;

-- Zone names accepted by this server's time zone database.
CREATE TABLE time_example.zone (
    zone_name text PRIMARY KEY
);
INSERT INTO time_example.zone (zone_name)
SELECT name FROM pg_timezone_names;

CREATE TABLE time_example.shop (
    shop_id bigint PRIMARY KEY,
    zone_name text NOT NULL REFERENCES time_example.zone (zone_name)
);

-- An instant, the zone in force when it was recorded, and the derived business day.
CREATE TABLE time_example.sale (
    sale_id bigint PRIMARY KEY,
    shop_id bigint NOT NULL REFERENCES time_example.shop (shop_id),
    occurred_at timestamptz(3) NOT NULL,
    zone_name text NOT NULL REFERENCES time_example.zone (zone_name),
    business_day date GENERATED ALWAYS AS
        ((occurred_at AT TIME ZONE zone_name)::date) STORED
);

-- A future wall-clock time: local fields plus the zone that gives them meaning.
CREATE TABLE time_example.appointment (
    appointment_id bigint PRIMARY KEY,
    shop_id bigint NOT NULL REFERENCES time_example.shop (shop_id),
    local_start timestamp(0) NOT NULL,
    local_end timestamp(0) NOT NULL,
    zone_name text NOT NULL REFERENCES time_example.zone (zone_name),
    CHECK (local_end > local_start)
);
CREATE VIEW time_example.appointment_instant AS
SELECT appointment_id,
       local_start AT TIME ZONE zone_name AS starts_at,
       local_end AT TIME ZONE zone_name AS ends_at
FROM time_example.appointment;

INSERT INTO time_example.shop VALUES (1, 'Asia/Tokyo'), (2, 'Europe/Berlin');

-- 23:30 UTC on March 1 is already March 2 in Tokyo.
INSERT INTO time_example.sale (sale_id, shop_id, occurred_at, zone_name)
SELECT 10, shop_id, TIMESTAMPTZ '2026-03-01 23:30:00+00', zone_name
FROM time_example.shop WHERE shop_id = 1;
SELECT (SELECT business_day = DATE '2026-03-02' FROM time_example.sale
        WHERE sale_id = 10) AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- The stored instant does not depend on the session time zone; its display does.
SET LOCAL TIME ZONE 'America/New_York';
SELECT occurred_at::text = '2026-03-01 18:30:00-05' AS valid
FROM time_example.sale WHERE sale_id = 10 \gset
\if :valid
\else
    \quit 1
\endif
SET LOCAL TIME ZONE 'UTC';

-- Precision is part of the column type: input is rounded to milliseconds.
INSERT INTO time_example.sale (sale_id, shop_id, occurred_at, zone_name)
VALUES (11, 2, TIMESTAMPTZ '2026-03-29 10:00:00.1235+00', 'Europe/Berlin');
SELECT (SELECT occurred_at = TIMESTAMPTZ '2026-03-29 10:00:00.124+00'
        FROM time_example.sale WHERE sale_id = 11) AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- A local business day is a half-open range of instants; it is not always 24 hours.
SELECT (DATE '2026-03-30'::timestamp AT TIME ZONE 'Europe/Berlin')
     - (DATE '2026-03-29'::timestamp AT TIME ZONE 'Europe/Berlin') = interval '23 hours'
   AND (DATE '2026-10-26'::timestamp AT TIME ZONE 'Europe/Berlin')
     - (DATE '2026-10-25'::timestamp AT TIME ZONE 'Europe/Berlin') = interval '25 hours'
   AS valid \gset
\if :valid
\else
    \quit 1
\endif
SELECT count(*) = 1 AS valid
FROM time_example.sale
WHERE occurred_at >= DATE '2026-03-29'::timestamp AT TIME ZONE 'Europe/Berlin'
  AND occurred_at <  DATE '2026-03-30'::timestamp AT TIME ZONE 'Europe/Berlin' \gset
\if :valid
\else
    \quit 1
\endif

-- Wall-clock times that do not exist or occur twice are resolved, not rejected.
SELECT TIMESTAMP '2026-03-29 02:30' AT TIME ZONE 'Europe/Berlin'
         = TIMESTAMPTZ '2026-03-29 01:30:00+00'
   AND TIMESTAMP '2026-10-25 02:30' AT TIME ZONE 'Europe/Berlin'
         = TIMESTAMPTZ '2026-10-25 01:30:00+00' AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- Calendar arithmetic follows the session zone: a day is not 24 hours across a transition.
SET LOCAL TIME ZONE 'Europe/Berlin';
SELECT TIMESTAMPTZ '2026-03-28 12:00+01' + interval '1 day'
         = TIMESTAMPTZ '2026-03-29 12:00+02'
   AND TIMESTAMPTZ '2026-03-28 12:00+01' + interval '24 hours'
         = TIMESTAMPTZ '2026-03-29 13:00+02' AS valid \gset
\if :valid
\else
    \quit 1
\endif
SET LOCAL TIME ZONE 'UTC';

-- A future appointment keeps its local time; the instant is derived when read.
INSERT INTO time_example.appointment VALUES
    (20, 2, TIMESTAMP '2027-04-01 09:00', TIMESTAMP '2027-04-01 09:30', 'Europe/Berlin');
SELECT (SELECT starts_at = TIMESTAMPTZ '2027-04-01 07:00:00+00'
        FROM time_example.appointment_instant WHERE appointment_id = 20) AS valid \gset
\if :valid
\else
    \quit 1
\endif

-- An unknown zone name is rejected by the reference, not discovered at read time.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO time_example.appointment VALUES
    (21, 2, TIMESTAMP '2027-04-01 10:00', TIMESTAMP '2027-04-01 10:30', 'Europe/Berlinn');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- The generated business day cannot be written directly.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE time_example.sale SET business_day = DATE '2026-03-01' WHERE sale_id = 10;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '428C9' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- now() is the transaction start; clock_timestamp() keeps moving.
SELECT now() = transaction_timestamp()
   AND pg_sleep(0.01) IS NOT NULL
   AND clock_timestamp() > now() AS valid \gset
\if :valid
\else
    \quit 1
\endif

ROLLBACK;

-- Converting timestamp to timestamptz under a UTC session keeps the table file.
BEGIN;
SET LOCAL TIME ZONE 'UTC';
CREATE TABLE legacy_event (recorded_at timestamp NOT NULL);
INSERT INTO legacy_event VALUES ('2026-01-15 08:00');
SELECT pg_relation_filenode('legacy_event') AS before_node \gset
ALTER TABLE legacy_event ALTER COLUMN recorded_at TYPE timestamptz;
SELECT pg_relation_filenode('legacy_event') = :before_node
   AND (SELECT recorded_at = TIMESTAMPTZ '2026-01-15 08:00:00+00' FROM legacy_event)
   AS valid \gset
\if :valid
\else
    \quit 1
\endif
ROLLBACK;
