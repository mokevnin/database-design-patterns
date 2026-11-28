-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f recurrence-rule.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA recurrence_example;
SET LOCAL search_path = recurrence_example, public;

-- Zone names accepted by this server's time zone database (see the Time Point chapter).
CREATE TABLE zone (
    zone_name text PRIMARY KEY
);
INSERT INTO zone (zone_name) SELECT name FROM pg_timezone_names;

-- The series row is the rule: the first occurrence in local time, the zone and the
-- RRULE parts this schema supports, as typed columns.
CREATE TABLE series (
    series_id bigint PRIMARY KEY,
    title text NOT NULL,
    zone_name text NOT NULL REFERENCES zone (zone_name),
    local_start timestamp(0) NOT NULL,                 -- DTSTART, wall clock
    duration interval NOT NULL CHECK (duration > interval '0'),
    freq text NOT NULL CHECK (freq IN ('weekly', 'monthly')),
    every_n integer NOT NULL DEFAULT 1 CHECK (every_n BETWEEN 1 AND 99),  -- INTERVAL
    by_weekday smallint[] CHECK (by_weekday <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]),
    by_month_day smallint CHECK (by_month_day BETWEEN -1 AND 31 AND by_month_day <> 0),
    short_month text CHECK (short_month IN ('skip', 'last_day')),
    local_stop timestamp(0),                           -- exclusive bound, unlike UNTIL
    max_count integer CHECK (max_count > 0),           -- COUNT
    split_from bigint REFERENCES series (series_id),
    revision integer NOT NULL DEFAULT 0,
    CONSTRAINT series_until_or_count CHECK (local_stop IS NULL OR max_count IS NULL),
    CONSTRAINT series_stop_after_start CHECK (local_stop > local_start),
    CONSTRAINT series_weekly_shape CHECK (freq <> 'weekly' OR (
        coalesce(cardinality(by_weekday), 0) > 0
        AND by_month_day IS NULL AND short_month IS NULL)),
    CONSTRAINT series_monthly_shape CHECK (freq <> 'monthly' OR (
        by_weekday IS NULL AND by_month_day IS NOT NULL AND short_month IS NOT NULL)),
    -- DTSTART is the first occurrence, so it must match the rule.
    CONSTRAINT series_start_matches_rule CHECK (CASE freq
        WHEN 'weekly' THEN extract(isodow FROM local_start)::smallint = ANY (by_weekday)
        WHEN 'monthly' THEN CASE WHEN by_month_day = -1
            THEN local_start::date = (date_trunc('month', local_start)
                                      + interval '1 month' - interval '1 day')::date
            ELSE extract(day FROM local_start) = by_month_day END
        END)
);

-- One row per changed occurrence, keyed by the occurrence's original local start
-- (RECURRENCE-ID). cancelled = EXDATE; local_start/duration = a moved instance.
CREATE TABLE occurrence_override (
    series_id bigint NOT NULL REFERENCES series (series_id),
    original_local_start timestamp(0) NOT NULL,
    cancelled boolean NOT NULL DEFAULT false,
    local_start timestamp(0),
    duration interval CHECK (duration > interval '0'),
    PRIMARY KEY (series_id, original_local_start),
    CONSTRAINT override_cancel_or_move CHECK (
        cancelled <> (local_start IS NOT NULL OR duration IS NOT NULL))
);

-- Expand a series into original local starts before p_until.
CREATE FUNCTION expand_series(p_series_id bigint, p_until timestamp)
RETURNS TABLE (original_local_start timestamp)
LANGUAGE sql STABLE AS $$
WITH s AS (
    SELECT * FROM series WHERE series_id = p_series_id
), candidate AS (
    -- Weekly: every day from the first week, kept when the weekday and week number match.
    SELECT d + s.local_start::time AS local_start
    FROM s, generate_series(date_trunc('week', s.local_start), p_until, interval '1 day') AS d
    WHERE s.freq = 'weekly'
      AND extract(isodow FROM d)::smallint = ANY (s.by_weekday)
      AND ((d::date - date_trunc('week', s.local_start)::date) / 7) % s.every_n = 0
    UNION ALL
    -- Monthly: step over first days of months, which always exist, then pick the day.
    SELECT m + make_interval(days => picked.day_no - 1) + s.local_start::time
    FROM s,
         generate_series(date_trunc('month', s.local_start), p_until,
                         make_interval(months => s.every_n)) AS m,
         LATERAL (SELECT extract(day FROM m + interval '1 month' - interval '1 day')::int
                  AS month_days) AS len,
         LATERAL (SELECT CASE
                      WHEN s.by_month_day = -1 THEN len.month_days
                      WHEN s.by_month_day <= len.month_days THEN s.by_month_day
                      WHEN s.short_month = 'last_day' THEN len.month_days
                  END AS day_no) AS picked
    WHERE s.freq = 'monthly' AND picked.day_no IS NOT NULL
), numbered AS (
    SELECT c.local_start, row_number() OVER (ORDER BY c.local_start) AS n
    FROM candidate AS c, s
    WHERE c.local_start >= s.local_start
      AND (s.local_stop IS NULL OR c.local_start < s.local_stop)
)
SELECT n.local_start
FROM numbered AS n, s
WHERE (s.max_count IS NULL OR n.n <= s.max_count)
  AND n.local_start < p_until
ORDER BY n.local_start
$$;

-- Materialized occurrences: a rebuildable projection that bookings can reference.
CREATE TABLE occurrence (
    occurrence_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    series_id bigint NOT NULL REFERENCES series (series_id),
    original_local_start timestamp(0) NOT NULL,
    local_start timestamp(0) NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    cancelled boolean NOT NULL,
    CONSTRAINT occurrence_natural_key UNIQUE (series_id, original_local_start),
    CHECK (ends_at > starts_at)
);
CREATE INDEX occurrence_starts_at_idx ON occurrence (starts_at);

CREATE TABLE attendance (
    occurrence_id bigint NOT NULL REFERENCES occurrence (occurrence_id),
    person text NOT NULL,
    PRIMARY KEY (occurrence_id, person)
);

-- Rule plus overrides, resolved in the series zone, upserted by the natural key.
-- Occurrences in the window that the rule no longer produces are deleted;
-- the attendance FK refuses to delete a booked one.
CREATE FUNCTION materialize(p_series_id bigint, p_from timestamp, p_to timestamp)
RETURNS void
LANGUAGE sql AS $$
-- Same lock as rule edits and override writers.
SELECT series_id FROM series WHERE series_id = p_series_id FOR UPDATE;

INSERT INTO occurrence AS oc
    (series_id, original_local_start, local_start, starts_at, ends_at, cancelled)
SELECT s.series_id, e.original_local_start, x.local_start,
       x.local_start AT TIME ZONE s.zone_name,
       (x.local_start + coalesce(o.duration, s.duration)) AT TIME ZONE s.zone_name,
       coalesce(o.cancelled, false)
FROM series AS s
CROSS JOIN LATERAL expand_series(s.series_id, p_to) AS e
LEFT JOIN occurrence_override AS o
       ON o.series_id = s.series_id AND o.original_local_start = e.original_local_start
CROSS JOIN LATERAL (SELECT coalesce(o.local_start, e.original_local_start)
                    AS local_start) AS x
WHERE s.series_id = p_series_id AND e.original_local_start >= p_from
ON CONFLICT (series_id, original_local_start) DO UPDATE
SET local_start = EXCLUDED.local_start, starts_at = EXCLUDED.starts_at,
    ends_at = EXCLUDED.ends_at, cancelled = EXCLUDED.cancelled
WHERE (oc.local_start, oc.starts_at, oc.ends_at, oc.cancelled)
      IS DISTINCT FROM
      (EXCLUDED.local_start, EXCLUDED.starts_at, EXCLUDED.ends_at, EXCLUDED.cancelled);

DELETE FROM occurrence AS oc
WHERE oc.series_id = p_series_id
  AND oc.original_local_start >= p_from AND oc.original_local_start < p_to
  AND NOT EXISTS (SELECT 1 FROM expand_series(p_series_id, p_to) AS e
                  WHERE e.original_local_start = oc.original_local_start);
$$;

INSERT INTO series (series_id, title, zone_name, local_start, duration, freq,
                    by_weekday, by_month_day, short_month, local_stop)
VALUES
    (1, 'Team meeting', 'Europe/Berlin', '2026-03-16 09:00', '30 minutes',
     'weekly', '{1}', NULL, NULL, NULL),
    (2, 'Evening class', 'Europe/Berlin', '2026-04-07 18:00', '90 minutes',
     'weekly', '{2,4}', NULL, NULL, '2026-07-01 00:00'),
    (3, 'Invoice, skip short months', 'Europe/Berlin', '2026-01-31 06:00', '1 hour',
     'monthly', NULL, 31, 'skip', '2026-07-01 00:00'),
    (4, 'Invoice, last day of short months', 'Europe/Berlin', '2026-01-31 06:00', '1 hour',
     'monthly', NULL, 31, 'last_day', '2026-07-01 00:00');

-- 09:00 in Berlin stays 09:00 across the March 29 transition; the UTC instant moves.
SELECT array_agg(e.original_local_start::time ORDER BY 1) = '{09:00,09:00,09:00,09:00}'
   AND array_agg((e.original_local_start AT TIME ZONE s.zone_name) ORDER BY 1)
       = ARRAY[TIMESTAMPTZ '2026-03-16 08:00+00', TIMESTAMPTZ '2026-03-23 08:00+00',
               TIMESTAMPTZ '2026-03-30 07:00+00', TIMESTAMPTZ '2026-04-06 07:00+00']
   AS valid
FROM series AS s, expand_series(s.series_id, TIMESTAMP '2026-04-07') AS e
WHERE s.series_id = 1 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- In autumn the instant moves back: 07:00 UTC on October 19, 08:00 UTC on October 26.
SELECT array_agg(e.original_local_start AT TIME ZONE s.zone_name ORDER BY 1)
       = ARRAY[TIMESTAMPTZ '2026-10-19 07:00+00', TIMESTAMPTZ '2026-10-26 08:00+00',
               TIMESTAMPTZ '2026-11-02 08:00+00']
   AS valid
FROM series AS s, expand_series(s.series_id, TIMESTAMP '2026-11-03') AS e
WHERE s.series_id = 1 AND e.original_local_start >= TIMESTAMP '2026-10-19' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Stepping a UTC instant by 7 days keeps 08:00 UTC, which becomes 10:00 in Berlin.
-- The zone-aware generate_series keeps the local time instead.
SELECT (SELECT array_agg(t) FROM generate_series(
            TIMESTAMPTZ '2026-03-23 08:00+00', TIMESTAMPTZ '2026-03-30 08:00+00',
            interval '7 days') AS t)
         = ARRAY[TIMESTAMPTZ '2026-03-23 08:00+00', TIMESTAMPTZ '2026-03-30 08:00+00']
   AND (TIMESTAMPTZ '2026-03-30 08:00+00' AT TIME ZONE 'Europe/Berlin')::time = '10:00'
   AND (SELECT array_agg(t) FROM generate_series(
            TIMESTAMPTZ '2026-03-23 08:00+00', TIMESTAMPTZ '2026-03-31 00:00+00',
            interval '7 days', 'Europe/Berlin') AS t)
         = ARRAY[TIMESTAMPTZ '2026-03-23 08:00+00', TIMESTAMPTZ '2026-03-30 07:00+00']
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Tuesday and Thursday classes from April 7 until the end of June: 25 occurrences.
SELECT count(*) = 25 AS valid
FROM expand_series(2, TIMESTAMP '2027-01-01') \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The 31st: RFC 5545 skips months without it; the other policy uses the last day.
SELECT (SELECT array_agg(original_local_start::date) FROM expand_series(3, '2027-01-01'))
         = '{2026-01-31,2026-03-31,2026-05-31}'::date[]
   AND (SELECT array_agg(original_local_start::date) FROM expand_series(4, '2027-01-01'))
         = '{2026-01-31,2026-02-28,2026-03-31,2026-04-30,2026-05-31,2026-06-30}'::date[]
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- generate_series adds the step to the previous value, so a monthly step drifts to the 28th.
-- Multiplying from the anchor clamps each month independently.
SELECT (SELECT array_agg(d::date) FROM generate_series(
            TIMESTAMP '2026-01-31', TIMESTAMP '2026-04-30', interval '1 month') AS d)
         = '{2026-01-31,2026-02-28,2026-03-28,2026-04-28}'::date[]
   AND (SELECT array_agg((TIMESTAMP '2026-01-31' + n * interval '1 month')::date)
        FROM generate_series(0, 3) AS n)
         = '{2026-01-31,2026-02-28,2026-03-31,2026-04-30}'::date[]
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- COUNT counts generated instances: the skip policy with COUNT 3 ends in May.
UPDATE series SET local_stop = NULL, max_count = 3 WHERE series_id = 3;
SELECT max(original_local_start)::date = DATE '2026-05-31' AS valid
FROM expand_series(3, TIMESTAMP '2027-01-01') \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The first occurrence must match the rule: a Wednesday start for a Tue/Thu class fails.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO series (series_id, title, zone_name, local_start, duration, freq, by_weekday)
VALUES (9, 'Misaligned class', 'Europe/Berlin', '2026-04-08 18:00', '90 minutes',
        'weekly', '{2,4}');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The same holds for monthly rules: a start on the 15th cannot anchor "the 31st".
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO series (series_id, title, zone_name, local_start, duration, freq,
                    by_month_day, short_month)
VALUES (9, 'Misaligned invoice', 'Europe/Berlin', '2026-01-15 06:00', '1 hour',
        'monthly', 31, 'skip');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- UNTIL and COUNT together are rejected, as RFC 5545 forbids.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE series SET local_stop = '2026-12-01 00:00' WHERE series_id = 3;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Exceptions: Easter Monday's meeting moves to Tuesday 11:00; Ascension Day's class is off.
INSERT INTO occurrence_override (series_id, original_local_start, local_start)
VALUES (1, '2026-04-06 09:00', '2026-04-07 11:00');
INSERT INTO occurrence_override (series_id, original_local_start, cancelled)
VALUES (2, '2026-05-14 18:00', true);
-- A cancelled instance still uses up one of the COUNT: EXDATE applies after the rule.
INSERT INTO occurrence_override (series_id, original_local_start, cancelled)
VALUES (3, '2026-03-31 06:00', true);

-- An override cannot both cancel and move the occurrence.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO occurrence_override (series_id, original_local_start, cancelled, local_start)
VALUES (2, '2026-05-21 18:00', true, '2026-05-22 18:00');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Materialize a window; running the job twice changes nothing.
SELECT count(materialize(series_id, TIMESTAMP '2026-01-01', TIMESTAMP '2026-07-01'))
FROM series \gset
SELECT count(*) AS first_run FROM occurrence \gset
SELECT count(materialize(series_id, TIMESTAMP '2026-01-01', TIMESTAMP '2026-07-01'))
FROM series \gset
SELECT count(*) = :first_run AND :first_run = 16 + 25 + 3 + 6 AS valid
FROM occurrence \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A plain duplicate insert is rejected by the natural key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO occurrence (series_id, original_local_start, local_start, starts_at, ends_at,
                        cancelled)
VALUES (1, '2026-03-16 09:00', '2026-03-16 09:00', '2026-03-16 08:00+00',
        '2026-03-16 08:30+00', false);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- What is on Tuesday, April 7, in Berlin? The moved meeting and the class.
SELECT array_agg(s.title || ' ' || o.local_start::time ORDER BY o.starts_at)
         = '{"Team meeting 11:00:00","Evening class 18:00:00"}' AS valid
FROM occurrence AS o JOIN series AS s USING (series_id)
WHERE NOT o.cancelled
  AND o.starts_at >= TIMESTAMP '2026-04-07 00:00' AT TIME ZONE 'Europe/Berlin'
  AND o.starts_at <  TIMESTAMP '2026-04-08 00:00' AT TIME ZONE 'Europe/Berlin' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT cancelled AS valid FROM occurrence
WHERE series_id = 2 AND original_local_start = '2026-05-14 18:00' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT array_agg(original_local_start::date ORDER BY 1)
         = '{2026-01-31,2026-03-31,2026-05-31}'::date[]
   AND count(*) FILTER (WHERE cancelled) = 1 AS valid
FROM occurrence WHERE series_id = 3 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bookings reference a concrete occurrence.
INSERT INTO attendance (occurrence_id, person)
SELECT occurrence_id, 'ana' FROM occurrence
WHERE series_id = 1 AND original_local_start = '2026-04-06 09:00';
INSERT INTO attendance (occurrence_id, person)
SELECT occurrence_id, 'ana' FROM occurrence
WHERE series_id = 1 AND original_local_start = '2026-04-27 09:00';
INSERT INTO attendance (occurrence_id, person)
SELECT occurrence_id, 'ben' FROM occurrence
WHERE series_id = 2 AND original_local_start = '2026-05-07 18:00';

-- A tzdata update: stand in for instants resolved under old rules, then re-materialize.
-- Instants are corrected, the override survives, occurrence IDs and bookings stay.
SELECT occurrence_id AS moved_id FROM occurrence
WHERE series_id = 1 AND original_local_start = '2026-04-06 09:00' \gset
UPDATE occurrence SET starts_at = starts_at + interval '1 hour',
                      ends_at = ends_at + interval '1 hour'
WHERE series_id = 1;
SELECT materialize(1, TIMESTAMP '2026-03-01', TIMESTAMP '2026-07-01') \gset
SELECT occurrence_id = :moved_id
   AND local_start = TIMESTAMP '2026-04-07 11:00'
   AND starts_at = TIMESTAMPTZ '2026-04-07 09:00+00'
   AND (SELECT count(*) FROM attendance AS a WHERE a.occurrence_id = o.occurrence_id) = 1
   AS valid
FROM occurrence AS o
WHERE series_id = 1 AND original_local_start = '2026-04-06 09:00' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A rule edit that would drop a booked occurrence is refused by the attendance FK.
SAVEPOINT rejected_operation;
UPDATE series SET by_weekday = '{2}', revision = revision + 1 WHERE series_id = 2;
\set ON_ERROR_STOP off
SELECT materialize(2, TIMESTAMP '2026-05-01', TIMESTAMP '2026-07-01') \gset
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A future cancellation in series 1 that the split must carry over.
INSERT INTO occurrence_override (series_id, original_local_start, cancelled)
VALUES (1, '2026-05-04 09:00', true);
SELECT materialize(1, TIMESTAMP '2026-03-01', TIMESTAMP '2026-07-01') \gset

-- An override writer reads revision 0 now and commits after the split below.
SELECT revision AS seen_revision FROM series WHERE series_id = 1 \gset

-- "This and following": from April 20 the meeting moves to 10:00.
-- Lock the series, end it at the boundary, start a successor, re-key future overrides,
-- re-point bookings, then re-materialize both series.
SELECT series_id AS locked_series FROM series WHERE series_id = 1 FOR UPDATE \gset
UPDATE series SET local_stop = '2026-04-20 09:00', revision = revision + 1
WHERE series_id = 1;
INSERT INTO series (series_id, title, zone_name, local_start, duration, freq, every_n,
                    by_weekday, split_from)
SELECT 5, title, zone_name, TIMESTAMP '2026-04-20 10:00', duration, freq, every_n,
       by_weekday, series_id
FROM series WHERE series_id = 1;
UPDATE occurrence_override
SET series_id = 5, original_local_start = original_local_start + interval '1 hour'
WHERE series_id = 1 AND original_local_start >= '2026-04-20 09:00';
SELECT materialize(5, TIMESTAMP '2026-04-20', TIMESTAMP '2026-07-01') \gset
UPDATE attendance AS a SET occurrence_id = new_oc.occurrence_id
FROM occurrence AS old_oc, occurrence AS new_oc
WHERE a.occurrence_id = old_oc.occurrence_id
  AND old_oc.series_id = 1 AND old_oc.original_local_start >= '2026-04-20 09:00'
  AND new_oc.series_id = 5
  AND new_oc.original_local_start = old_oc.original_local_start + interval '1 hour';
SELECT materialize(1, TIMESTAMP '2026-04-20', TIMESTAMP '2026-07-01') \gset

SELECT (SELECT max(original_local_start) FROM occurrence WHERE series_id = 1)
         = TIMESTAMP '2026-04-13 09:00'
   AND (SELECT min(starts_at) FROM occurrence WHERE series_id = 5)
         = TIMESTAMPTZ '2026-04-20 08:00+00'
   AND (SELECT cancelled FROM occurrence
        WHERE series_id = 5 AND original_local_start = '2026-05-04 10:00')
   AND (SELECT o.series_id = 5 AND o.local_start = '2026-04-27 10:00'
        FROM attendance AS a JOIN occurrence AS o USING (occurrence_id)
        WHERE a.person = 'ana' AND o.original_local_start >= '2026-04-20')
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The guarded override writer locks the series, checks the revision its client read,
-- and checks that the original start is an occurrence of the current rule.
-- A stale revision writes nothing, even for an occurrence that still exists.
\set target '2026-04-13 09:00'
\set client_revision :seen_revision
SELECT EXISTS (SELECT 1 FROM expand_series(1, TIMESTAMP '2026-07-01') AS e
               WHERE e.original_local_start = TIMESTAMP :'target') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH guarded AS (
    SELECT series_id FROM series
    WHERE series_id = 1 AND revision = :client_revision
      AND EXISTS (SELECT 1 FROM expand_series(1, TIMESTAMP '2026-07-01') AS e
                  WHERE e.original_local_start = TIMESTAMP :'target')
    FOR UPDATE
), written AS (
    INSERT INTO occurrence_override (series_id, original_local_start, cancelled)
    SELECT series_id, TIMESTAMP :'target', true FROM guarded
    RETURNING 1
)
SELECT count(*) = 0 AS valid FROM written \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The current revision with a start the rule no longer produces also writes nothing.
\set target '2026-05-11 09:00'
SELECT revision AS client_revision FROM series WHERE series_id = 1 \gset
WITH guarded AS (
    SELECT series_id FROM series
    WHERE series_id = 1 AND revision = :client_revision
      AND EXISTS (SELECT 1 FROM expand_series(1, TIMESTAMP '2026-07-01') AS e
                  WHERE e.original_local_start = TIMESTAMP :'target')
    FOR UPDATE
), written AS (
    INSERT INTO occurrence_override (series_id, original_local_start, cancelled)
    SELECT series_id, TIMESTAMP :'target', true FROM guarded
    RETURNING 1
)
SELECT count(*) = 0 AS valid FROM written \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The current revision with a real occurrence writes the override.
\set target '2026-04-13 09:00'
WITH guarded AS (
    SELECT series_id FROM series
    WHERE series_id = 1 AND revision = :client_revision
      AND EXISTS (SELECT 1 FROM expand_series(1, TIMESTAMP '2026-07-01') AS e
                  WHERE e.original_local_start = TIMESTAMP :'target')
    FOR UPDATE
), written AS (
    INSERT INTO occurrence_override (series_id, original_local_start, cancelled)
    SELECT series_id, TIMESTAMP :'target', true FROM guarded
    RETURNING 1
)
SELECT count(*) = 1 AS valid FROM written \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- DST gap: 02:30 on March 29 does not exist in Berlin. This schema keeps the occurrence
-- and lets AT TIME ZONE resolve it to 03:30 summer time (the Time Point rule);
-- RFC 5545 would omit it. The round trip finds such instances.
INSERT INTO series (series_id, title, zone_name, local_start, duration, freq, by_weekday,
                    max_count)
VALUES (6, 'Night backup', 'Europe/Berlin', '2026-03-22 02:30', '1 hour', 'weekly', '{7}', 3);
SELECT array_agg(e.original_local_start AT TIME ZONE s.zone_name ORDER BY 1)
         = ARRAY[TIMESTAMPTZ '2026-03-22 01:30+00', TIMESTAMPTZ '2026-03-29 01:30+00',
                 TIMESTAMPTZ '2026-04-05 00:30+00']
   AND array_agg(e.original_local_start ORDER BY 1) FILTER (
         WHERE (e.original_local_start AT TIME ZONE s.zone_name) AT TIME ZONE s.zone_name
               <> e.original_local_start)
         = ARRAY[TIMESTAMP '2026-03-29 02:30']
   AS valid
FROM series AS s, expand_series(s.series_id, TIMESTAMP '2026-05-01') AS e
WHERE s.series_id = 6 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
