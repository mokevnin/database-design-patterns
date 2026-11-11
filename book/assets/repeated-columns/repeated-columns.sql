-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f repeated-columns.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA repeated_columns_lab;
SET search_path TO repeated_columns_lab, public;

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

CREATE TABLE tag (tag_id bigint PRIMARY KEY, name text NOT NULL UNIQUE);
CREATE TABLE article_old (
    article_id bigint PRIMARY KEY,
    tag1 bigint REFERENCES tag (tag_id),
    tag2 bigint REFERENCES tag (tag_id),
    tag3 bigint REFERENCES tag (tag_id)
);
INSERT INTO tag VALUES (3, 'sql'), (7, 'schema'), (12, 'keys'), (15, 'queries');
INSERT INTO article_old VALUES (1, 3, 7, 3), (2, NULL, 12, NULL);
SELECT article_id FROM article_old
WHERE tag1 = 12 OR tag2 = 12 OR tag3 = 12;
SELECT article_id, tag1, tag2, tag3 FROM article_old WHERE article_id = 1;

CREATE TABLE article (article_id bigint PRIMARY KEY);
CREATE TABLE article_tag (
    article_id bigint NOT NULL REFERENCES article (article_id),
    tag_id bigint NOT NULL REFERENCES tag (tag_id),
    CONSTRAINT article_tag_pkey PRIMARY KEY (article_id, tag_id)
);
CREATE INDEX article_tag_tag_idx ON article_tag (tag_id, article_id);
CREATE TABLE tag_slot_archive (
    article_id bigint NOT NULL,
    slot integer NOT NULL,
    tag_id bigint NOT NULL,
    PRIMARY KEY (article_id, slot)
);
BEGIN;
LOCK TABLE article_old IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO article SELECT article_id FROM article_old;
INSERT INTO tag_slot_archive
SELECT a.article_id, v.slot, v.tag_id FROM article_old AS a
CROSS JOIN LATERAL (VALUES (1, a.tag1), (2, a.tag2), (3, a.tag3)) AS v(slot, tag_id)
WHERE v.tag_id IS NOT NULL;
INSERT INTO article_tag SELECT DISTINCT article_id, tag_id FROM tag_slot_archive;
COMMIT;
INSERT INTO article_tag VALUES (1, 12), (1, 15);
SELECT tag_id FROM article_tag WHERE article_id = 1 ORDER BY tag_id;
SELECT article_id FROM article_tag WHERE tag_id = 12 ORDER BY article_id;

SELECT pg_temp.expect_error($operation$INSERT INTO article_tag VALUES (1, 3);$operation$, '23505', 'duplicate key value violates unique constraint "article_tag_pkey"');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 5 FROM article_tag);
    ASSERT (SELECT count(*) = 4 FROM tag_slot_archive);
END $$;
