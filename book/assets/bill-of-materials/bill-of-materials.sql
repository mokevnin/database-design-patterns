-- Checked on PostgreSQL 18.6 (Homebrew).
-- Structural writers acquire the table lock BEFORE reads, at Read Committed.
-- Quantities are component pieces per one parent piece; no unit conversion.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA bom_example;
SET search_path = bom_example, public;

CREATE TABLE part (
    part_id bigint PRIMARY KEY,
    part_code text NOT NULL UNIQUE
);
CREATE TABLE part_version (
    version_id bigint PRIMARY KEY,
    part_id bigint NOT NULL REFERENCES part (part_id),
    revision integer NOT NULL CHECK (revision > 0),
    kind text NOT NULL CHECK (kind IN ('assembly', 'leaf')),
    state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'released')),
    UNIQUE (part_id, revision),
    UNIQUE (version_id, part_id, state)
);
CREATE TABLE bom_line (
    parent_version_id bigint REFERENCES part_version (version_id),
    child_version_id bigint REFERENCES part_version (version_id),
    quantity numeric NOT NULL CHECK (quantity > 0 AND quantity < 'Infinity'::numeric),
    PRIMARY KEY (parent_version_id, child_version_id),
    CHECK (parent_version_id <> child_version_id)
);
CREATE INDEX bom_line_child_idx ON bom_line (child_version_id);
CREATE TABLE assembly_schedule (
    part_id bigint REFERENCES part (part_id),
    valid_at daterange NOT NULL CHECK (NOT lower_inf(valid_at)),
    version_id bigint NOT NULL,
    version_state text NOT NULL DEFAULT 'released' CHECK (version_state = 'released'),
    PRIMARY KEY (part_id, valid_at WITHOUT OVERLAPS),
    FOREIGN KEY (version_id, part_id, version_state)
        REFERENCES part_version (version_id, part_id, state)
);
CREATE FUNCTION guard_bom_line() RETURNS trigger LANGUAGE plpgsql SET search_path = bom_example, pg_temp AS $$
DECLARE
    parent_id bigint;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'replace a draft line with delete and insert' USING ERRCODE = '23514';
    END IF;
    parent_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.parent_version_id ELSE NEW.parent_version_id END;
    IF EXISTS (SELECT FROM part_version WHERE version_id = parent_id
               AND (state = 'released' OR kind = 'leaf')) THEN
        RAISE EXCEPTION 'BOM parent must be a draft assembly' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    IF EXISTS (
        WITH RECURSIVE reachable(id) AS (
            VALUES (NEW.child_version_id)
            UNION
            SELECT b.child_version_id FROM bom_line AS b JOIN reachable AS r
                ON b.parent_version_id = r.id
        )
        SELECT FROM reachable WHERE id = NEW.parent_version_id
    ) THEN
        RAISE EXCEPTION 'bill of materials cycle' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER bom_line_guard BEFORE INSERT OR UPDATE OR DELETE ON bom_line
    FOR EACH ROW EXECUTE FUNCTION guard_bom_line();
CREATE FUNCTION guard_part_version() RETURNS trigger LANGUAGE plpgsql SET search_path = bom_example, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.state <> 'draft' THEN
            RAISE EXCEPTION 'create versions in draft' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.state = 'released' THEN
        RAISE EXCEPTION 'released version is immutable' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    IF (NEW.version_id, NEW.part_id, NEW.revision, NEW.kind)
        IS DISTINCT FROM (OLD.version_id, OLD.part_id, OLD.revision, OLD.kind) THEN
        RAISE EXCEPTION 'version identity and kind are immutable' USING ERRCODE = '23514';
    END IF;
    IF NEW.state = 'released' AND (
        (NEW.kind = 'assembly' AND NOT EXISTS
            (SELECT FROM bom_line WHERE parent_version_id = NEW.version_id))
        OR EXISTS (SELECT FROM bom_line AS b JOIN part_version AS c
                   ON c.version_id = b.child_version_id
                   WHERE b.parent_version_id = NEW.version_id AND c.state <> 'released')
    ) THEN
        RAISE EXCEPTION 'release children before their nonempty assembly' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER part_version_guard BEFORE INSERT OR UPDATE OR DELETE ON part_version
    FOR EACH ROW EXECUTE FUNCTION guard_part_version();

BEGIN;
LOCK TABLE part_version, bom_line IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO part VALUES (1, 'bicycle'), (2, 'wheel'), (3, 'spoke'), (4, 'rim'), (5, 'frame');
INSERT INTO part_version (version_id, part_id, revision, kind) VALUES
    (10, 1, 1, 'assembly'), (20, 2, 1, 'assembly'),
    (30, 3, 1, 'leaf'), (40, 4, 1, 'leaf'), (50, 5, 1, 'leaf');
INSERT INTO bom_line VALUES (10, 20, 2), (10, 50, 1), (20, 30, 32), (20, 40, 1), (10, 30, 4);
UPDATE part_version SET state = 'released' WHERE version_id IN (30, 40, 50);
UPDATE part_version SET state = 'released' WHERE version_id = 20;
UPDATE part_version SET state = 'released' WHERE version_id = 10;
COMMIT;

WITH RECURSIVE explosion(version_id, required) AS (
    VALUES (10::bigint, 1::numeric)
    UNION ALL
    SELECT b.child_version_id, e.required * b.quantity
    FROM explosion AS e JOIN bom_line AS b ON b.parent_version_id = e.version_id
)
SELECT p.part_code, sum(e.required) AS pieces
FROM explosion AS e JOIN part_version AS v USING (version_id)
JOIN part AS p USING (part_id)
WHERE v.kind = 'leaf' GROUP BY p.part_code ORDER BY p.part_code;

BEGIN;
LOCK TABLE part_version, bom_line IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO part_version (version_id, part_id, revision, kind) VALUES (11, 1, 2, 'assembly');
INSERT INTO bom_line
SELECT 11, child_version_id, CASE WHEN child_version_id = 20 THEN 3 ELSE quantity END
FROM bom_line WHERE parent_version_id = 10;
UPDATE part_version SET state = 'released' WHERE version_id = 11;
COMMIT;
INSERT INTO assembly_schedule (part_id, valid_at, version_id) VALUES
    (1, '[2026-01-01,2027-01-01)', 10), (1, '[2027-01-01,)', 11);
SELECT version_id FROM assembly_schedule
WHERE part_id = 1 AND valid_at @> DATE '2027-02-01';

BEGIN;
LOCK TABLE part_version, bom_line IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO part VALUES (6, 'draft-A'), (7, 'draft-B');
INSERT INTO part_version (version_id, part_id, revision, kind)
VALUES (60, 6, 1, 'assembly'), (70, 7, 1, 'assembly');
INSERT INTO bom_line VALUES (60, 70, 1);
DO $$
BEGIN
    BEGIN
        INSERT INTO bom_line VALUES (70, 60, 1);
        RAISE EXCEPTION 'expected graph cycle';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'bill of materials cycle' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        DELETE FROM bom_line WHERE parent_version_id = 10 AND child_version_id = 20;
        RAISE EXCEPTION 'expected frozen BOM';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'BOM parent must be a draft assembly' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT (SELECT quantity FROM bom_line WHERE parent_version_id = 10 AND child_version_id = 20) = 2;
END $$;
COMMIT;
