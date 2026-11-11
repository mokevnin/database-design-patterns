-- Checked on PostgreSQL 18.6.
-- Run with psql -X -v ON_ERROR_STOP=1 -f adjacency-list.sql in an empty database.
-- Every structural writer must lock before reading the tree, at READ COMMITTED.
\set ON_ERROR_STOP on
CREATE TABLE category (
    category_id bigint PRIMARY KEY,
    name text NOT NULL,
    parent_id bigint,
    CONSTRAINT category_parent_fk FOREIGN KEY (parent_id)
        REFERENCES category (category_id),
    CONSTRAINT category_not_self CHECK (parent_id <> category_id)
);
CREATE INDEX category_parent_idx ON category (parent_id);

CREATE FUNCTION reject_category_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        WITH RECURSIVE ancestors AS (
            SELECT category_id, parent_id FROM category
            WHERE category_id = NEW.parent_id
            UNION
            SELECT c.category_id, c.parent_id
            FROM category AS c JOIN ancestors AS a
                ON c.category_id = a.parent_id
        )
        SELECT 1 FROM ancestors WHERE category_id = NEW.category_id
    ) THEN
        RAISE EXCEPTION 'category cycle' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER category_cycle
BEFORE INSERT OR UPDATE OF parent_id ON category
FOR EACH ROW EXECUTE FUNCTION reject_category_cycle();

BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO category VALUES (1, 'Catalog', NULL);
INSERT INTO category VALUES (2, 'Books', 1), (3, 'Tools', 1);
INSERT INTO category VALUES (4, 'SQL', 2);
COMMIT;

-- Descendants, including the selected node; sort by the ID path.
WITH RECURSIVE subtree AS (
    SELECT category_id, name, ARRAY[category_id] AS path
    FROM category WHERE category_id = 1
    UNION ALL
    SELECT c.category_id, c.name, s.path || c.category_id
    FROM category AS c JOIN subtree AS s ON c.parent_id = s.category_id
)
SELECT category_id, name, path FROM subtree ORDER BY path;

-- Breadcrumbs, root first.
WITH RECURSIVE ancestors AS (
    SELECT category_id, parent_id, name, 0 AS distance
    FROM category WHERE category_id = 4
    UNION ALL
    SELECT c.category_id, c.parent_id, c.name, a.distance + 1
    FROM category AS c JOIN ancestors AS a ON c.category_id = a.parent_id
)
SELECT category_id, name FROM ancestors ORDER BY distance DESC;

BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
UPDATE category SET parent_id = 3 WHERE category_id = 2;
COMMIT;
SELECT category_id, parent_id FROM category ORDER BY category_id;

-- Catch only the expected failure, and verify the exact diagnostic.
BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
DO $$
DECLARE message text;
BEGIN
    BEGIN
        UPDATE category SET parent_id = 4 WHERE category_id = 3;
        RAISE EXCEPTION 'expected cycle rejection';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        ASSERT message = 'category cycle';
        RAISE NOTICE 'expected SQLSTATE 23514: %', message;
    END;
END;
$$;
COMMIT;

-- Explicit subtree deletion; no implicit cascade policy.
BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
WITH RECURSIVE subtree AS (
    SELECT category_id FROM category WHERE category_id = 2
    UNION ALL
    SELECT c.category_id FROM category AS c
    JOIN subtree AS s ON c.parent_id = s.category_id
)
DELETE FROM category WHERE category_id IN (SELECT category_id FROM subtree);
COMMIT;
SELECT category_id FROM category ORDER BY category_id;
