-- Checked on PostgreSQL 18.6 (Homebrew).
-- One configured unit per numeric phenomenon; normalize before insertion.
\set ON_ERROR_STOP on
CREATE SCHEMA observation_example;
SET search_path = observation_example, public;

CREATE TABLE subject (subject_id bigint PRIMARY KEY, label text NOT NULL);
CREATE TABLE observer (observer_id bigint PRIMARY KEY, label text NOT NULL);
CREATE TABLE phenomenon (
    phenomenon_code text PRIMARY KEY,
    value_kind text NOT NULL CHECK (value_kind IN ('number', 'category')),
    unit_code text,
    UNIQUE (phenomenon_code, value_kind),
    UNIQUE (phenomenon_code, unit_code),
    CHECK ((value_kind = 'number' AND unit_code IS NOT NULL)
        OR (value_kind = 'category' AND unit_code IS NULL))
);
CREATE TABLE category (
    phenomenon_code text REFERENCES phenomenon (phenomenon_code),
    category_code text,
    PRIMARY KEY (phenomenon_code, category_code)
);
CREATE TABLE observation (
    observation_id bigint PRIMARY KEY,
    source_key text NOT NULL UNIQUE,
    subject_id bigint NOT NULL REFERENCES subject (subject_id),
    phenomenon_code text NOT NULL,
    value_kind text NOT NULL,
    number_value numeric,
    unit_code text,
    category_code text,
    method text NOT NULL,
    observer_id bigint NOT NULL REFERENCES observer (observer_id),
    observed_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    supersedes bigint UNIQUE,
    UNIQUE (observation_id, subject_id, phenomenon_code),
    FOREIGN KEY (phenomenon_code, value_kind) REFERENCES phenomenon (phenomenon_code, value_kind),
    FOREIGN KEY (phenomenon_code, unit_code) REFERENCES phenomenon (phenomenon_code, unit_code),
    FOREIGN KEY (phenomenon_code, category_code) REFERENCES category (phenomenon_code, category_code),
    FOREIGN KEY (supersedes, subject_id, phenomenon_code)
        REFERENCES observation (observation_id, subject_id, phenomenon_code),
    CHECK (supersedes < observation_id),
    CONSTRAINT observation_value_shape CHECK (
        (value_kind = 'number' AND number_value IS NOT NULL
         AND number_value > '-Infinity'::numeric AND number_value < 'Infinity'::numeric
         AND unit_code IS NOT NULL AND category_code IS NULL)
        OR (value_kind = 'category' AND category_code IS NOT NULL
            AND number_value IS NULL AND unit_code IS NULL)
    )
);
CREATE TABLE rejection (
    observation_id bigint PRIMARY KEY REFERENCES observation (observation_id),
    reviewer_id bigint NOT NULL REFERENCES observer (observer_id),
    reason text NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX observation_latest_idx
    ON observation (subject_id, phenomenon_code, observed_at DESC, observation_id DESC);
CREATE FUNCTION reject_fact_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path = observation_example, pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'observation facts are immutable' USING ERRCODE = '23514';
END $$;
CREATE TRIGGER observation_immutable BEFORE UPDATE OR DELETE ON observation
    FOR EACH ROW EXECUTE FUNCTION reject_fact_mutation();
CREATE TRIGGER rejection_immutable BEFORE UPDATE OR DELETE ON rejection
    FOR EACH ROW EXECUTE FUNCTION reject_fact_mutation();
CREATE VIEW observation_state AS
SELECT o.*, CASE
    WHEN EXISTS (SELECT FROM rejection AS r WHERE r.observation_id = o.observation_id) THEN 'rejected'
    WHEN EXISTS (SELECT FROM observation AS n WHERE n.supersedes = o.observation_id) THEN 'superseded'
    ELSE 'active' END AS status
FROM observation AS o;

INSERT INTO subject VALUES (1, 'Batch A');
INSERT INTO observer VALUES (1, 'Scale operator'), (2, 'Quality reviewer');
INSERT INTO phenomenon VALUES ('mass', 'number', 'kg'), ('appearance', 'category', NULL);
INSERT INTO category VALUES ('appearance', 'pass'), ('appearance', 'fail');
INSERT INTO observation
    (observation_id, source_key, subject_id, phenomenon_code, value_kind,
     number_value, unit_code, method, observer_id, observed_at)
VALUES (10, 'scale:10', 1, 'mass', 'number', 20, 'kg', 'bench scale', 1, '2026-11-01 10:00Z');
INSERT INTO observation
    (observation_id, source_key, subject_id, phenomenon_code, value_kind,
     category_code, method, observer_id, observed_at)
VALUES (11, 'inspection:11', 1, 'appearance', 'category', 'pass', 'visual', 2, '2026-11-01 10:01Z');

BEGIN;
SELECT subject_id FROM subject WHERE subject_id = 1 FOR UPDATE;
INSERT INTO observation
    (observation_id, source_key, subject_id, phenomenon_code, value_kind,
     number_value, unit_code, method, observer_id, observed_at, supersedes)
VALUES (12, 'scale:12', 1, 'mass', 'number', 2, 'kg', 'recalibrated scale', 1,
        '2026-11-01 10:00Z', 10);
COMMIT;
INSERT INTO observation
    (observation_id, source_key, subject_id, phenomenon_code, value_kind,
     number_value, unit_code, method, observer_id, observed_at)
VALUES (13, 'scale:13', 1, 'mass', 'number', 99, 'kg', 'bench scale', 1, '2026-11-02 10:00Z');
INSERT INTO rejection (observation_id, reviewer_id, reason) VALUES (13, 2, 'Wrong batch on scale');
SELECT observation_id, number_value, unit_code
FROM observation_state
WHERE subject_id = 1 AND phenomenon_code = 'mass' AND status = 'active'
ORDER BY observed_at DESC, observation_id DESC LIMIT 1;
SELECT observation_id, status FROM observation_state ORDER BY observation_id;

DO $$
BEGIN
    BEGIN
        UPDATE observation SET number_value = 3 WHERE observation_id = 12;
        RAISE EXCEPTION 'expected immutable fact';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'observation facts are immutable' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO observation
            (observation_id, source_key, subject_id, phenomenon_code, value_kind,
             number_value, unit_code, category_code, method, observer_id, observed_at)
        VALUES (14, 'bad:14', 1, 'mass', 'number', 2, 'kg', 'pass', 'bad', 1, now());
        RAISE EXCEPTION 'expected value-shape violation';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM NOT LIKE '%observation_value_shape%' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO observation
            (observation_id, source_key, subject_id, phenomenon_code, value_kind,
             number_value, unit_code, method, observer_id, observed_at, supersedes)
        VALUES (15, 'scale:15', 1, 'mass', 'number', 3, 'kg', 'second correction', 1,
                '2026-11-01 10:00Z', 10);
        RAISE EXCEPTION 'expected replacement conflict';
    EXCEPTION WHEN unique_violation THEN
        IF SQLERRM NOT LIKE '%observation_supersedes_key%' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT (SELECT status FROM observation_state WHERE observation_id = 10) = 'superseded';
    ASSERT (SELECT status FROM observation_state WHERE observation_id = 12) = 'active';
    ASSERT (SELECT status FROM observation_state WHERE observation_id = 13) = 'rejected';
END $$;
