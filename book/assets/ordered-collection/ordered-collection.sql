-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f ordered-collection.sql in an empty database.
-- Expected errors are intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on

CREATE TABLE playlist (
    playlist_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE playlist_item (
    item_id bigint PRIMARY KEY,
    playlist_id bigint NOT NULL REFERENCES playlist (playlist_id)
        ON DELETE CASCADE,
    title text NOT NULL,
    position bigint NOT NULL CHECK (position >= 0),
    CONSTRAINT playlist_item_position_key UNIQUE (playlist_id, position)
        DEFERRABLE INITIALLY IMMEDIATE
);
INSERT INTO playlist VALUES (1, 'Launch');
INSERT INTO playlist_item VALUES
    (1, 1, 'Intro', 1024),
    (2, 1, 'Demo', 2048),
    (3, 1, 'Credits', 3072);

BEGIN;
SELECT playlist_id FROM playlist WHERE playlist_id = 1 FOR UPDATE;
SELECT item_id, position FROM playlist_item
WHERE playlist_id = 1 ORDER BY position;
INSERT INTO playlist_item VALUES (4, 1, 'Setup', 1536);
UPDATE playlist_item SET position = 1280
WHERE playlist_id = 1 AND item_id = 3;
COMMIT;
SELECT item_id, title, position FROM playlist_item
WHERE playlist_id = 1 ORDER BY position;

BEGIN;
SELECT playlist_id FROM playlist WHERE playlist_id = 1 FOR UPDATE;
SET CONSTRAINTS playlist_item_position_key DEFERRED;
WITH ranked AS (
    SELECT item_id,
           row_number() OVER (ORDER BY position, item_id) * 1024 AS new_position
    FROM playlist_item WHERE playlist_id = 1
)
UPDATE playlist_item AS i SET position = r.new_position
FROM ranked AS r WHERE i.item_id = r.item_id;
COMMIT;

DO $$ BEGIN
    ASSERT (SELECT array_agg(item_id ORDER BY position) = ARRAY[1,3,4,2]::bigint[] FROM playlist_item WHERE playlist_id = 1);
END $$;

DO $$ BEGIN
    ASSERT (SELECT array_agg(position ORDER BY position) = ARRAY[1024,2048,3072,4096]::bigint[] FROM playlist_item WHERE playlist_id = 1);
END $$;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
UPDATE playlist_item SET position = 1024
WHERE playlist_id = 1 AND item_id = 2;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- Swapping two positions requires temporary duplicate positions.
BEGIN;
SELECT playlist_id FROM playlist WHERE playlist_id = 1 FOR UPDATE;
SET CONSTRAINTS playlist_item_position_key DEFERRED;
UPDATE playlist_item SET position = 2048 WHERE item_id = 1;
UPDATE playlist_item SET position = 1024 WHERE item_id = 3;
COMMIT;

DO $$ BEGIN
    ASSERT (SELECT array_agg(item_id ORDER BY position) = ARRAY[3,1,4,2]::bigint[] FROM playlist_item WHERE playlist_id = 1);
END $$;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
BEGIN;
SET CONSTRAINTS playlist_item_position_key DEFERRED;
UPDATE playlist_item SET position = 1024 WHERE item_id = 2;
COMMIT;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

DO $$ BEGIN
    ASSERT (SELECT position = 4096 FROM playlist_item WHERE item_id = 2);
END $$;
