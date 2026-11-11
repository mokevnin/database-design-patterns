-- Checked on PostgreSQL 18.6.
-- Run with psql -X -v ON_ERROR_STOP=1 -f closure-table.sql in an empty database.
-- All structural writers lock category, then category_path, before any reads.
\set ON_ERROR_STOP on
CREATE TABLE category (
    category_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE category_path (
    ancestor_id bigint REFERENCES category (category_id) ON DELETE CASCADE,
    descendant_id bigint REFERENCES category (category_id) ON DELETE CASCADE,
    depth integer NOT NULL,
    PRIMARY KEY (ancestor_id, descendant_id),
    CONSTRAINT category_path_depth CHECK (
        (ancestor_id = descendant_id AND depth = 0)
        OR (ancestor_id <> descendant_id AND depth > 0)
    )
);
CREATE INDEX category_path_descendant_idx
    ON category_path (descendant_id, ancestor_id) INCLUDE (depth);
CREATE UNIQUE INDEX category_one_parent
    ON category_path (descendant_id) WHERE depth = 1;

BEGIN;
LOCK TABLE category, category_path IN SHARE ROW EXCLUSIVE MODE;
INSERT INTO category VALUES (1, 'Catalog');
INSERT INTO category_path VALUES (1, 1, 0);
INSERT INTO category VALUES (2, 'Books');
INSERT INTO category_path
SELECT ancestor_id, 2, depth + 1 FROM category_path WHERE descendant_id = 1
UNION ALL SELECT 2, 2, 0;
INSERT INTO category VALUES (3, 'Tools');
INSERT INTO category_path
SELECT ancestor_id, 3, depth + 1 FROM category_path WHERE descendant_id = 1
UNION ALL SELECT 3, 3, 0;
INSERT INTO category VALUES (4, 'SQL');
INSERT INTO category_path
SELECT ancestor_id, 4, depth + 1 FROM category_path WHERE descendant_id = 2
UNION ALL SELECT 4, 4, 0;
COMMIT;

SELECT c.category_id, c.name, p.depth
FROM category_path AS p JOIN category AS c ON c.category_id = p.descendant_id
WHERE p.ancestor_id = 2 ORDER BY p.depth, c.category_id;
SELECT c.category_id, c.name, p.depth
FROM category_path AS p JOIN category AS c ON c.category_id = p.ancestor_id
WHERE p.descendant_id = 4 ORDER BY p.depth DESC;

BEGIN;
LOCK TABLE category, category_path IN SHARE ROW EXCLUSIVE MODE;
-- Check before deleting any evidence of the old ancestry.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM category_path
               WHERE ancestor_id = 2 AND descendant_id = 3) THEN
        RAISE EXCEPTION 'category cycle' USING ERRCODE = '23514';
    END IF;
    ASSERT EXISTS (SELECT 1 FROM category WHERE category_id = 2);
    ASSERT EXISTS (SELECT 1 FROM category WHERE category_id = 3);
END;
$$;
DELETE FROM category_path AS p
USING category_path AS old_ancestor, category_path AS subtree
WHERE old_ancestor.descendant_id = 2 AND old_ancestor.ancestor_id <> 2
  AND subtree.ancestor_id = 2
  AND p.ancestor_id = old_ancestor.ancestor_id
  AND p.descendant_id = subtree.descendant_id;
INSERT INTO category_path
SELECT a.ancestor_id, s.descendant_id, a.depth + 1 + s.depth
FROM category_path AS a CROSS JOIN category_path AS s
WHERE a.descendant_id = 3 AND s.ancestor_id = 2;
COMMIT;
SELECT ancestor_id, descendant_id, depth
FROM category_path WHERE descendant_id = 4 ORDER BY depth DESC;

DO $$
DECLARE message text;
BEGIN
    BEGIN
        INSERT INTO category_path VALUES (4, 4, 1);
        RAISE EXCEPTION 'expected depth rejection';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        ASSERT message = 'new row for relation "category_path" violates check constraint "category_path_depth"';
        RAISE NOTICE 'expected SQLSTATE 23514: %', message;
    END;
END;
$$;

-- Compare stored closure with closure derived from the depth-one edges.
DO $$
BEGIN
    ASSERT NOT EXISTS (
        WITH RECURSIVE expected(ancestor_id, descendant_id, depth) AS (
            SELECT category_id, category_id, 0 FROM category
            UNION ALL
            SELECT e.ancestor_id, p.descendant_id, e.depth + 1
            FROM expected AS e JOIN category_path AS p
            ON p.ancestor_id = e.descendant_id AND p.depth = 1
        )
        (SELECT * FROM expected EXCEPT SELECT * FROM category_path)
        UNION ALL
        (SELECT * FROM category_path EXCEPT SELECT * FROM expected)
    ), 'closure differs from parent edges';
END;
$$;

BEGIN;
LOCK TABLE category, category_path IN SHARE ROW EXCLUSIVE MODE;
DELETE FROM category WHERE category_id IN (
    SELECT descendant_id FROM category_path WHERE ancestor_id = 2
);
COMMIT;
SELECT category_id FROM category ORDER BY category_id;
