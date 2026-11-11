-- Checked on PostgreSQL 18.6.
-- Run with psql -X -v ON_ERROR_STOP=1 -f nested-sets.sql in an empty database.
-- Dense numbering and noncrossing intervals are maintained by the write protocol.
\set ON_ERROR_STOP on
CREATE TABLE category (
    category_id bigint PRIMARY KEY,
    name text NOT NULL,
    lft bigint NOT NULL,
    rgt bigint NOT NULL,
    CONSTRAINT category_bounds CHECK (lft > 0 AND lft < rgt),
    CONSTRAINT category_left_key UNIQUE (lft) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT category_right_key UNIQUE (rgt) DEFERRABLE INITIALLY DEFERRED
);
INSERT INTO category VALUES
    (1, 'Catalog', 1, 8), (2, 'Books', 2, 5),
    (4, 'SQL', 3, 4), (3, 'Tools', 6, 7);

SELECT c.category_id, c.name FROM category AS p
JOIN category AS c ON c.lft BETWEEN p.lft AND p.rgt
WHERE p.category_id = 2 ORDER BY c.lft;
SELECT (rgt - lft - 1) / 2 AS descendants
FROM category WHERE category_id = 2;
SELECT p.category_id FROM category AS c
JOIN category AS p ON p.lft < c.lft AND p.rgt > c.rgt
WHERE c.category_id = 4 ORDER BY p.lft;

-- Insert a last child of Books at its old right endpoint, 5.
BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE insertion ON COMMIT DROP AS
SELECT rgt AS pos FROM category WHERE category_id = 2;
UPDATE category SET
    lft = CASE WHEN lft >= i.pos THEN lft + 2 ELSE lft END,
    rgt = CASE WHEN rgt >= i.pos THEN rgt + 2 ELSE rgt END
FROM insertion AS i WHERE rgt >= i.pos;
INSERT INTO category
SELECT 5, 'Indexes', pos, pos + 1 FROM insertion;
COMMIT;

-- Move Books, including SQL and Indexes, to the last-child slot of Tools.
BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
WITH move AS (
    SELECT s.lft AS lo, s.rgt AS hi, s.rgt - s.lft + 1 AS width,
           d.rgt AS target
    FROM category AS s CROSS JOIN category AS d
    WHERE s.category_id = 2 AND d.category_id = 3
      AND NOT d.lft BETWEEN s.lft AND s.rgt
)
UPDATE category SET
    lft = CASE
        WHEN lft BETWEEN m.lo AND m.hi THEN lft +
            CASE WHEN m.target < m.lo THEN m.target - m.lo
                 ELSE m.target - m.hi - 1 END
        WHEN m.target < m.lo AND lft >= m.target AND lft < m.lo
            THEN lft + m.width
        WHEN m.target > m.hi AND lft > m.hi AND lft < m.target
            THEN lft - m.width
        ELSE lft END,
    rgt = CASE
        WHEN rgt BETWEEN m.lo AND m.hi THEN rgt +
            CASE WHEN m.target < m.lo THEN m.target - m.lo
                 ELSE m.target - m.hi - 1 END
        WHEN m.target < m.lo AND rgt >= m.target AND rgt < m.lo
            THEN rgt + m.width
        WHEN m.target > m.hi AND rgt > m.hi AND rgt < m.target
            THEN rgt - m.width
        ELSE rgt END
FROM move AS m;
COMMIT;
SELECT category_id, lft, rgt FROM category ORDER BY lft;

DO $$
DECLARE message text;
BEGIN
    BEGIN
        INSERT INTO category VALUES (99, 'Invalid', 12, 11);
        RAISE EXCEPTION 'expected bounds rejection';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        ASSERT message = 'new row for relation "category" violates check constraint "category_bounds"';
        RAISE NOTICE 'expected SQLSTATE 23514: %', message;
    END;
END;
$$;

-- Verify invariants that the two endpoint UNIQUE constraints do not enforce.
DO $$
BEGIN
    ASSERT NOT EXISTS (
        SELECT 1 FROM category a JOIN category b
        ON a.lft < b.lft AND b.lft < a.rgt AND a.rgt < b.rgt
    ), 'crossing intervals';
    ASSERT (SELECT count(DISTINCT endpoint) = 2 * (SELECT count(*) FROM category)
                   AND min(endpoint) = 1
                   AND max(endpoint) = 2 * (SELECT count(*) FROM category)
            FROM (SELECT lft AS endpoint FROM category UNION ALL
                  SELECT rgt FROM category) AS endpoints), 'not dense';
END;
$$;

-- Delete Books and its descendants and close the gap.
BEGIN;
LOCK TABLE category IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE removal ON COMMIT DROP AS
SELECT lft AS lo, rgt AS hi, rgt - lft + 1 AS width
FROM category WHERE category_id = 2;
DELETE FROM category USING removal AS r WHERE lft BETWEEN r.lo AND r.hi;
UPDATE category SET
    lft = CASE WHEN lft > r.hi THEN lft - r.width ELSE lft END,
    rgt = CASE WHEN rgt > r.hi THEN rgt - r.width ELSE rgt END
FROM removal AS r WHERE rgt > r.hi;
COMMIT;
SELECT category_id, lft, rgt FROM category ORDER BY lft;
