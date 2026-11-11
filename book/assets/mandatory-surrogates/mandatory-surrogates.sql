-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f mandatory-surrogates.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA mandatory_surrogates_lab;
SET search_path TO mandatory_surrogates_lab, public;

CREATE OR REPLACE FUNCTION pg_temp.expect_error(command text, expected_state text, expected_message text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual_state text;
    actual_message text;
BEGIN
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE,
            actual_message = MESSAGE_TEXT;
    END;
    IF actual_state IS DISTINCT FROM expected_state
       OR actual_message IS DISTINCT FROM expected_message THEN
        RAISE EXCEPTION 'Expected %: %, got %: %', expected_state,
            expected_message, actual_state, actual_message;
    END IF;
    RAISE NOTICE 'Expected %: %', actual_state, actual_message;
END;
$$;

CREATE TABLE project (project_id bigint PRIMARY KEY);
CREATE TABLE person (person_id bigint PRIMARY KEY);
CREATE TABLE membership_old (
    membership_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id bigint NOT NULL REFERENCES project (project_id),
    person_id bigint NOT NULL REFERENCES person (person_id)
);
INSERT INTO project VALUES (10);
INSERT INTO person VALUES (1), (2);
INSERT INTO membership_old (project_id, person_id) VALUES (10, 1), (10, 1), (10, 2);
SELECT project_id, count(*) AS members FROM membership_old GROUP BY project_id;

CREATE TABLE membership (
    project_id bigint NOT NULL REFERENCES project (project_id),
    person_id bigint NOT NULL REFERENCES person (person_id),
    CONSTRAINT membership_pkey PRIMARY KEY (project_id, person_id)
);
CREATE INDEX membership_person_idx ON membership (person_id, project_id);
CREATE TABLE membership_id_map (
    old_membership_id bigint PRIMARY KEY REFERENCES membership_old (membership_id),
    project_id bigint NOT NULL,
    person_id bigint NOT NULL,
    FOREIGN KEY (project_id, person_id) REFERENCES membership (project_id, person_id)
);
BEGIN;
LOCK TABLE membership_old IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO membership SELECT DISTINCT project_id, person_id FROM membership_old;
INSERT INTO membership_id_map
SELECT membership_id, project_id, person_id FROM membership_old;
COMMIT;
SELECT project_id, count(*) AS members FROM membership GROUP BY project_id;
SELECT * FROM membership_id_map ORDER BY old_membership_id;

SELECT pg_temp.expect_error($operation$INSERT INTO membership VALUES (10, 1);$operation$, '23505', 'duplicate key value violates unique constraint "membership_pkey"');

BEGIN;
LOCK TABLE membership_old IN SHARE ROW EXCLUSIVE MODE;
-- Only this lab has no incoming references except its retained ID map.
-- Keep the old rows and demonstrate the alternative on a separate table.
CREATE TABLE membership_handle (
    membership_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id bigint NOT NULL REFERENCES project (project_id),
    person_id bigint NOT NULL REFERENCES person (person_id),
    UNIQUE (project_id, person_id)
);
INSERT INTO membership_handle (project_id, person_id)
SELECT project_id, person_id FROM membership;
COMMIT;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 2 FROM membership);
    ASSERT (SELECT count(*) = 3 FROM membership_id_map);
END $$;
