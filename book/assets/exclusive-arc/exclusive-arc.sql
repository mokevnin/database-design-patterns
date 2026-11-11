-- Checked on PostgreSQL 18.6. Run with psql -X -v ON_ERROR_STOP=1 -f this-file.sql.
BEGIN;
CREATE SCHEMA arc_lab;
SET LOCAL search_path = arc_lab, public;

CREATE TABLE post (post_id bigint PRIMARY KEY, title text NOT NULL);
CREATE TABLE photo (photo_id bigint PRIMARY KEY, caption text NOT NULL);
CREATE TABLE comment (
    comment_id bigint PRIMARY KEY,
    body text NOT NULL,
    post_id bigint REFERENCES post (post_id) ON DELETE CASCADE,
    photo_id bigint REFERENCES photo (photo_id) ON DELETE CASCADE,
    CONSTRAINT comment_one_parent CHECK (
        (post_id IS NOT NULL AND photo_id IS NULL)
        OR (post_id IS NULL AND photo_id IS NOT NULL)
    )
);
CREATE INDEX comment_post_idx ON comment (post_id) WHERE post_id IS NOT NULL;
CREATE INDEX comment_photo_idx ON comment (photo_id) WHERE photo_id IS NOT NULL;
INSERT INTO post VALUES (1, 'Schema notes');
INSERT INTO photo VALUES (2, 'Whiteboard');
INSERT INTO comment VALUES (10, 'Useful', 1, NULL);
SELECT comment_id, body FROM comment WHERE post_id = 1;
DO $$
BEGIN
    BEGIN
        INSERT INTO comment VALUES (11, 'Ambiguous', 1, 2);
        RAISE EXCEPTION 'Expected both-parents rejection';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'new row for relation "comment" violates check constraint "comment_one_parent"' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO comment VALUES (12, 'Orphan', NULL, NULL);
        RAISE EXCEPTION 'Expected no-parent rejection';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'Expected no-parent SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO comment VALUES (13, 'Missing target', 999, NULL);
        RAISE EXCEPTION 'Expected missing-target rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected missing-target SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
UPDATE comment SET post_id = NULL, photo_id = 2 WHERE comment_id = 10;
DELETE FROM post WHERE post_id = 1;
SELECT comment_id, photo_id FROM comment;
DELETE FROM photo WHERE photo_id = 2;
SELECT count(*) AS remaining_comments FROM comment;
ROLLBACK;
