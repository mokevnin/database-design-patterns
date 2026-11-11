-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f delimited-lists.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA delimited_lists_lab;
SET search_path TO delimited_lists_lab, public;

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
CREATE TABLE article_old (article_id bigint PRIMARY KEY, tag_ids text NOT NULL);
INSERT INTO tag VALUES (3, 'sql'), (7, 'schema'), (12, 'keys');
INSERT INTO article_old VALUES (1, '3,7,12'), (2, '12'), (3, '7,999');
SELECT article_id FROM article_old WHERE tag_ids LIKE '%3%' ORDER BY article_id;
SELECT article_id FROM article_old WHERE tag_ids LIKE '%2%' ORDER BY article_id;

CREATE TABLE article (article_id bigint PRIMARY KEY);
CREATE TABLE article_tag (
    article_id bigint NOT NULL REFERENCES article (article_id),
    tag_id bigint NOT NULL REFERENCES tag (tag_id),
    CONSTRAINT article_tag_pkey PRIMARY KEY (article_id, tag_id)
);
CREATE INDEX article_tag_reverse_idx ON article_tag (tag_id, article_id);
CREATE TABLE tag_reject (
    article_id bigint NOT NULL,
    token text NOT NULL,
    reason text NOT NULL
);
BEGIN;
LOCK TABLE article_old IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO article SELECT article_id FROM article_old;
CREATE TEMP TABLE tag_token ON COMMIT DROP AS
SELECT a.article_id, btrim(t.token) AS token
FROM article_old AS a
CROSS JOIN LATERAL unnest(string_to_array(a.tag_ids, ',')) AS t(token);
INSERT INTO tag_reject
SELECT t.article_id, t.token, 'unknown or noncanonical tag ID'
FROM tag_token AS t LEFT JOIN tag AS g ON g.tag_id::text = t.token
WHERE g.tag_id IS NULL;
INSERT INTO article_tag
SELECT DISTINCT t.article_id, g.tag_id
FROM tag_token AS t JOIN tag AS g ON g.tag_id::text = t.token;
COMMIT;
SELECT article_id FROM article_tag WHERE tag_id = 12 ORDER BY article_id;
SELECT * FROM tag_reject ORDER BY article_id, token;

SELECT pg_temp.expect_error($operation$INSERT INTO article_tag VALUES (1, 999);$operation$, '23503', 'insert or update on table "article_tag" violates foreign key constraint "article_tag_tag_id_fkey"');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 5 FROM article_tag);
    ASSERT (SELECT count(*) = 1 FROM tag_reject);
END $$;
