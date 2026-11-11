-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f history-table.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA history_example;
CREATE TABLE history_example.item (
    item_id bigint PRIMARY KEY,
    retired boolean NOT NULL DEFAULT false
);
CREATE TABLE history_example.item_current (
    item_id bigint PRIMARY KEY REFERENCES history_example.item (item_id),
    label text NOT NULL,
    recorded_from timestamptz NOT NULL
);
CREATE TABLE history_example.item_history (
    item_id bigint REFERENCES history_example.item (item_id),
    recorded_from timestamptz NOT NULL,
    recorded_to timestamptz NOT NULL,
    label text NOT NULL,
    PRIMARY KEY (item_id, recorded_from),
    CHECK (recorded_from < recorded_to)
);
CREATE FUNCTION history_example.keep_version()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    boundary timestamptz;
BEGIN
    -- Serialize creation/reuse checks with archival of this identity.
    PERFORM 1 FROM history_example.item
    WHERE item_id = CASE WHEN TG_OP = 'INSERT' THEN NEW.item_id ELSE OLD.item_id END
    FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF (SELECT retired FROM history_example.item WHERE item_id = NEW.item_id) THEN
            RAISE EXCEPTION 'item identity cannot be reused'
                USING ERRCODE = '23514';
        END IF;
        NEW.recorded_from := clock_timestamp();
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.item_id IS DISTINCT FROM OLD.item_id THEN
        RAISE EXCEPTION 'item identity is immutable' USING ERRCODE = '23514';
    END IF;
    boundary := greatest(clock_timestamp(),
                         OLD.recorded_from + interval '1 microsecond');
    INSERT INTO history_example.item_history
        (item_id, recorded_from, recorded_to, label)
    VALUES (OLD.item_id, OLD.recorded_from, boundary, OLD.label);
    IF TG_OP = 'DELETE' THEN
        UPDATE history_example.item SET retired = true WHERE item_id = OLD.item_id;
        RETURN OLD;
    END IF;
    NEW.recorded_from := boundary;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION history_example.keep_version() FROM PUBLIC;
CREATE TRIGGER keep_version BEFORE INSERT OR UPDATE OR DELETE
ON history_example.item_current
FOR EACH ROW EXECUTE FUNCTION history_example.keep_version();
CREATE VIEW history_example.item_versions AS
SELECT item_id, label, recorded_from, recorded_to
FROM history_example.item_history
UNION ALL
SELECT item_id, label, recorded_from, NULL::timestamptz
FROM history_example.item_current;

INSERT INTO history_example.item VALUES (1);
INSERT INTO history_example.item_current (item_id, label)
VALUES (1, 'Draft');
UPDATE history_example.item_current SET label = 'Published' WHERE item_id = 1;
SELECT label FROM history_example.item_versions
WHERE item_id = 1
  AND recorded_from <= (SELECT min(recorded_from)
                       FROM history_example.item_history WHERE item_id = 1)
  AND (recorded_to IS NULL OR recorded_to >
       (SELECT min(recorded_from) FROM history_example.item_history WHERE item_id = 1));

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE history_example.item_current SET item_id = 2 WHERE item_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

DELETE FROM history_example.item_current WHERE item_id = 1;
SELECT count(*) AS archived_versions FROM history_example.item_history;
SELECT (SELECT count(*) = 2 FROM history_example.item_history)
   AND NOT EXISTS (SELECT FROM history_example.item_current)
   AND NOT EXISTS (
       SELECT FROM history_example.item_history AS a
       JOIN history_example.item_history AS b USING (item_id)
       WHERE a.recorded_from < b.recorded_from
         AND a.recorded_to <> b.recorded_from
   ) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
SAVEPOINT resurrection;
\set ON_ERROR_STOP off
INSERT INTO history_example.item_current (item_id, label) VALUES (1, 'Reused');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT resurrection;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

-- Retention demo: expire the first version; a service supplies its policy cutoff.
WITH cutoff AS (
    SELECT min(recorded_to) AS retain_from FROM history_example.item_history
), expired AS (
    SELECT item_id, recorded_from FROM history_example.item_history, cutoff
    WHERE recorded_to <= retain_from ORDER BY recorded_to LIMIT 1000
)
DELETE FROM history_example.item_history AS h USING expired AS e
WHERE h.item_id = e.item_id AND h.recorded_from = e.recorded_from;
SELECT (SELECT count(*) = 1 FROM history_example.item_history)
    AND (SELECT retired FROM history_example.item WHERE item_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
ROLLBACK;
