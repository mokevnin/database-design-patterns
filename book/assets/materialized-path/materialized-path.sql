-- Checked on PostgreSQL 18.6, with the supplied ltree extension.
-- Run with psql -X -v ON_ERROR_STOP=1 -f materialized-path.sql in an empty database.
\set ON_ERROR_STOP on
CREATE EXTENSION ltree;
CREATE TABLE category (
    category_id bigint PRIMARY KEY CHECK (category_id > 0),
    name text NOT NULL,
    parent_id bigint,
    path ltree NOT NULL UNIQUE,
    parent_path ltree GENERATED ALWAYS AS (
        CASE WHEN nlevel(path) > 1
             THEN subpath(path, 0, nlevel(path) - 1) END
    ) STORED,
    UNIQUE (category_id, path),
    CONSTRAINT category_path_shape CHECK (
        nlevel(path) > 0
        AND subpath(path, -1) = text2ltree(category_id::text)
        AND ((parent_id IS NULL) = (nlevel(path) = 1))
    ),
    CONSTRAINT category_parent_path_fk FOREIGN KEY (parent_id, parent_path)
        REFERENCES category (category_id, path) MATCH FULL
        DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX category_path_gist ON category USING gist (path);
CREATE INDEX category_parent_idx ON category (parent_id, parent_path);

BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO category (category_id, name, parent_id, path)
VALUES (1, 'Catalog', NULL, '1');
INSERT INTO category (category_id, name, parent_id, path)
SELECT 2, 'Books', category_id, path || '2'::ltree
FROM category WHERE category_id = 1;
INSERT INTO category (category_id, name, parent_id, path)
VALUES (3, 'Tools', 1, '1.3'), (4, 'SQL', 2, '1.2.4');
COMMIT;

SELECT category_id, path FROM category
WHERE path <@ '1.2'::ltree ORDER BY path;
SELECT category_id, name FROM category
WHERE path @> '1.2.4'::ltree ORDER BY nlevel(path);
SELECT category_id FROM category
WHERE parent_id = 1 ORDER BY category_id;

BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
SET CONSTRAINTS category_parent_path_fk DEFERRED;
WITH moving AS (
    SELECT s.category_id, s.path AS old_path,
           d.category_id AS new_parent_id,
           d.path || text2ltree(s.category_id::text) AS new_path
    FROM category AS s CROSS JOIN category AS d
    WHERE s.category_id = 2 AND d.category_id = 3
      AND NOT d.path <@ s.path
)
UPDATE category AS c
SET path = CASE WHEN c.category_id = m.category_id THEN m.new_path
                ELSE m.new_path || subpath(c.path, nlevel(m.old_path)) END,
    parent_id = CASE WHEN c.category_id = m.category_id
                     THEN m.new_parent_id ELSE c.parent_id END
FROM moving AS m WHERE c.path <@ m.old_path;
SET CONSTRAINTS category_parent_path_fk IMMEDIATE;
COMMIT;
SELECT category_id, path FROM category ORDER BY path;

DO $$
DECLARE message text;
BEGIN
    BEGIN
        UPDATE category SET parent_id = 1 WHERE category_id = 4;
        RAISE EXCEPTION 'expected parent/path rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        ASSERT message = 'insert or update on table "category" violates foreign key constraint "category_parent_path_fk"';
        RAISE NOTICE 'expected SQLSTATE 23503: %', message;
    END;
END;
$$;

BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
DELETE FROM category WHERE path <@ '1.3.2'::ltree;
COMMIT;
SELECT category_id FROM category ORDER BY category_id;
