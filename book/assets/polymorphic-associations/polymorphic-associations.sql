-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f polymorphic-associations.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA polymorphic_associations_lab;
SET search_path TO polymorphic_associations_lab, public;

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

CREATE TABLE post (post_id bigint PRIMARY KEY, title text NOT NULL);
CREATE TABLE photo (photo_id bigint PRIMARY KEY, caption text NOT NULL);
CREATE TABLE comment_old (
    comment_id bigint PRIMARY KEY,
    body text NOT NULL,
    target_type text NOT NULL CHECK (target_type IN ('post', 'photo')),
    target_id bigint NOT NULL
);
INSERT INTO post VALUES (1, 'Schema notes');
INSERT INTO photo VALUES (1, 'Whiteboard');
INSERT INTO comment_old VALUES
    (10, 'Useful', 'post', 1), (11, 'Clear', 'photo', 1), (12, 'Lost', 'post', 999);
SELECT c.comment_id FROM comment_old AS c
LEFT JOIN post AS p ON c.target_type = 'post' AND c.target_id = p.post_id
LEFT JOIN photo AS f ON c.target_type = 'photo' AND c.target_id = f.photo_id
WHERE p.post_id IS NULL AND f.photo_id IS NULL;

CREATE TABLE comment (
    comment_id bigint PRIMARY KEY,
    body text NOT NULL,
    post_id bigint REFERENCES post (post_id),
    photo_id bigint REFERENCES photo (photo_id),
    CONSTRAINT comment_one_target CHECK (
        (post_id IS NOT NULL AND photo_id IS NULL)
        OR (post_id IS NULL AND photo_id IS NOT NULL)
    )
);
CREATE INDEX comment_post_idx ON comment (post_id);
CREATE INDEX comment_photo_idx ON comment (photo_id);
CREATE TABLE comment_reject (LIKE comment_old INCLUDING ALL);
BEGIN;
LOCK TABLE comment_old, post, photo IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO comment
SELECT c.comment_id, c.body,
       CASE WHEN c.target_type = 'post' THEN p.post_id END,
       CASE WHEN c.target_type = 'photo' THEN f.photo_id END
FROM comment_old AS c
LEFT JOIN post AS p ON c.target_type = 'post' AND c.target_id = p.post_id
LEFT JOIN photo AS f ON c.target_type = 'photo' AND c.target_id = f.photo_id
WHERE p.post_id IS NOT NULL OR f.photo_id IS NOT NULL;
INSERT INTO comment_reject
SELECT c.* FROM comment_old AS c
WHERE NOT EXISTS (SELECT 1 FROM comment AS n WHERE n.comment_id = c.comment_id);
COMMIT;
SELECT comment_id, body FROM comment WHERE post_id = 1;
SELECT comment_id, target_type, target_id FROM comment_reject;

SELECT pg_temp.expect_error($operation$INSERT INTO comment VALUES (13, 'Ambiguous', 1, 1);$operation$, '23514', 'new row for relation "comment" violates check constraint "comment_one_target"');

SELECT pg_temp.expect_error($operation$INSERT INTO comment VALUES (14, 'Missing', 999, NULL);$operation$, '23503', 'insert or update on table "comment" violates foreign key constraint "comment_post_id_fkey"');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 2 FROM comment);
    ASSERT (SELECT count(*) = 1 FROM comment_reject);
END $$;
