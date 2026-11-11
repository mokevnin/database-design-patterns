-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f fixed-depth-queries.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA fixed_depth_queries_lab;
SET search_path TO fixed_depth_queries_lab, public;

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

CREATE TABLE category (
    category_id bigint PRIMARY KEY,
    parent_id bigint,
    name text NOT NULL,
    CONSTRAINT category_parent_fk FOREIGN KEY (parent_id) REFERENCES category (category_id),
    CONSTRAINT category_not_self CHECK (parent_id <> category_id)
);
CREATE INDEX category_parent_idx ON category (parent_id);
INSERT INTO category VALUES
    (1, NULL, 'Catalog'), (2, 1, 'Books'), (3, 2, 'Databases'), (4, 3, 'PostgreSQL');
SELECT c.category_id FROM category AS c
LEFT JOIN category AS p ON p.category_id = c.parent_id
LEFT JOIN category AS gp ON gp.category_id = p.parent_id
WHERE c.category_id = 1 OR p.category_id = 1 OR gp.category_id = 1
ORDER BY c.category_id;

WITH RECURSIVE subtree AS (
    SELECT category_id, parent_id, name, 0 AS depth FROM category WHERE category_id = 1
    UNION ALL
    SELECT c.category_id, c.parent_id, c.name, s.depth + 1
    FROM category AS c JOIN subtree AS s ON c.parent_id = s.category_id
) CYCLE category_id SET is_cycle USING path
SELECT category_id, name, depth FROM subtree WHERE NOT is_cycle ORDER BY path;

SELECT pg_temp.expect_error($operation$INSERT INTO category VALUES (5, 999, 'Missing parent');$operation$, '23503', 'insert or update on table "category" violates foreign key constraint "category_parent_fk"');

BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
UPDATE category SET parent_id = 4 WHERE category_id = 1;
WITH RECURSIVE walk AS (
    SELECT category_id, parent_id, 0 AS depth FROM category WHERE category_id = 1
    UNION ALL
    SELECT c.category_id, c.parent_id, w.depth + 1
    FROM category AS c JOIN walk AS w ON c.parent_id = w.category_id
) CYCLE category_id SET is_cycle USING path
SELECT category_id, depth, is_cycle FROM walk WHERE is_cycle;
ROLLBACK;

DO $$ BEGIN
    ASSERT (SELECT parent_id IS NULL FROM category WHERE category_id = 1);
    ASSERT (WITH RECURSIVE s AS (
        SELECT category_id FROM category WHERE category_id = 1
        UNION ALL SELECT c.category_id FROM category c JOIN s ON c.parent_id = s.category_id
    ) SELECT count(*) = 4 FROM s);
END $$;
