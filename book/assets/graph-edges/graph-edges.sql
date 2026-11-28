-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f graph-edges.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
-- The concurrent race is emulated in one session: see the chapter for the two-session run.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA graph_example;
SET LOCAL search_path = graph_example;

CREATE TABLE project (
    project_id bigint PRIMARY KEY,
    name text NOT NULL
);

-- Nodes. The (project_id, issue_id) key lets edges prove both ends share a project.
CREATE TABLE issue (
    issue_id bigint PRIMARY KEY,
    project_id bigint NOT NULL REFERENCES project (project_id),
    title text NOT NULL,
    UNIQUE (project_id, issue_id)
);

-- Edges: one row per directed pair and kind, with the edge's own attributes.
CREATE TABLE issue_link (
    project_id bigint NOT NULL,
    from_issue_id bigint NOT NULL,
    to_issue_id bigint NOT NULL,
    kind text NOT NULL CHECK (kind IN ('blocks', 'relates')),
    lag_days integer NOT NULL DEFAULT 0 CHECK (lag_days >= 0),
    PRIMARY KEY (from_issue_id, to_issue_id, kind),
    CONSTRAINT issue_link_from_fk FOREIGN KEY (project_id, from_issue_id)
        REFERENCES issue (project_id, issue_id) ON DELETE CASCADE,
    CONSTRAINT issue_link_to_fk FOREIGN KEY (project_id, to_issue_id)
        REFERENCES issue (project_id, issue_id) ON DELETE CASCADE,
    CONSTRAINT issue_link_no_self_loop CHECK (from_issue_id <> to_issue_id),
    CONSTRAINT issue_link_relates_canonical
        CHECK (kind <> 'relates' OR from_issue_id < to_issue_id),
    CONSTRAINT issue_link_lag_only_on_blocks CHECK (kind = 'blocks' OR lag_days = 0)
);
CREATE INDEX issue_link_to_idx ON issue_link (to_issue_id, kind);

-- A symmetric relation is stored once and read in both directions.
CREATE VIEW related_issue AS
SELECT from_issue_id AS issue_id, to_issue_id AS related_issue_id
FROM issue_link WHERE kind = 'relates'
UNION ALL
SELECT to_issue_id, from_issue_id
FROM issue_link WHERE kind = 'relates';

-- Blocking links must stay acyclic. Lock the project (the component), then
-- walk downstream from the new target looking for the new source.
-- Correct at Read Committed: each statement in a volatile function takes a
-- fresh snapshot, so the walk after the lock wait sees the other commit.
CREATE FUNCTION reject_blocking_cycle() RETURNS trigger
LANGUAGE plpgsql SET search_path = graph_example, pg_temp AS $$
BEGIN
    -- Other kinds may form cycles; the row check rejects self-loops.
    IF NEW.kind <> 'blocks' OR NEW.from_issue_id = NEW.to_issue_id THEN
        RETURN NEW;
    END IF;
    PERFORM FROM project WHERE project_id = NEW.project_id FOR NO KEY UPDATE;
    IF EXISTS (
        WITH RECURSIVE downstream(issue_id) AS (
            VALUES (NEW.to_issue_id)
            UNION
            SELECT l.to_issue_id
            FROM issue_link AS l JOIN downstream AS d ON l.from_issue_id = d.issue_id
            WHERE l.kind = 'blocks'
        )
        SELECT FROM downstream WHERE issue_id = NEW.from_issue_id
    ) THEN
        RAISE EXCEPTION 'blocking link % -> % would close a cycle',
            NEW.from_issue_id, NEW.to_issue_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER issue_link_acyclic
BEFORE INSERT OR UPDATE OF from_issue_id, to_issue_id, kind ON issue_link
FOR EACH ROW EXECUTE FUNCTION reject_blocking_cycle();

INSERT INTO project VALUES (1, 'Release 2.0'), (2, 'Mobile app');
INSERT INTO issue VALUES
    (1, 1, 'Design schema'), (2, 1, 'Write migration'), (3, 1, 'Update API'),
    (4, 1, 'Ship release'), (5, 1, 'Write docs'),
    (6, 2, 'A'), (7, 2, 'B'), (8, 2, 'C'), (9, 2, 'D');

-- A diamond: 1 blocks 2 and 3, both block 4; docs also block the release.
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind, lag_days) VALUES
    (1, 1, 2, 'blocks', 0), (1, 1, 3, 'blocks', 2),
    (1, 2, 4, 'blocks', 1), (1, 3, 4, 'blocks', 0), (1, 5, 4, 'blocks', 0);
-- Symmetric links, stored with the smaller ID first.
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES
    (1, 2, 5, 'relates'), (1, 3, 5, 'relates');

-- Everything that blocks issue 4, breadth first. The diamond yields issue 1 twice.
CREATE TEMP TABLE blockers_of_4 AS
WITH RECURSIVE upstream(issue_id, depth, lag_total) AS (
    SELECT from_issue_id, 1, lag_days
    FROM issue_link WHERE to_issue_id = 4 AND kind = 'blocks'
    UNION ALL
    SELECT l.from_issue_id, u.depth + 1, u.lag_total + l.lag_days
    FROM issue_link AS l JOIN upstream AS u ON l.to_issue_id = u.issue_id
    WHERE l.kind = 'blocks' AND u.depth < 10
) SEARCH BREADTH FIRST BY issue_id SET ord
SELECT issue_id, depth, lag_total, row_number() OVER (ORDER BY ord) AS ord FROM upstream;
SELECT count(*) = 5 AND count(DISTINCT issue_id) = 4
   AND string_agg(issue_id::text, ',' ORDER BY ord) = '2,3,5,1,1' AS valid
FROM blockers_of_4 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Reachability as distinct nodes with their minimum depth.
SELECT string_agg(issue_id || ':' || depth, ',' ORDER BY issue_id) = '1:2,2:1,3:1,5:1' AS valid
FROM (SELECT issue_id, min(depth) AS depth FROM blockers_of_4 GROUP BY issue_id) AS r \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Weighted: the longest lag chain in front of issue 4 runs through issue 3.
SELECT max(lag_total) = 2 AS valid FROM blockers_of_4 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The symmetric view turns every relates link into an immediate two-cycle.
-- A depth limit alone revisits the start; CYCLE marks the closing row.
SELECT count(*) = 3 AND count(*) FILTER (WHERE related_issue_id = 2) = 1 AS valid
FROM (
    WITH RECURSIVE walk(issue_id, related_issue_id, depth) AS (
        SELECT issue_id, related_issue_id, 1 FROM related_issue WHERE issue_id = 2
        UNION ALL
        SELECT r.issue_id, r.related_issue_id, w.depth + 1
        FROM related_issue AS r JOIN walk AS w ON r.issue_id = w.related_issue_id
        WHERE w.depth < 2
    )
    SELECT * FROM walk
) AS limited \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
CREATE TEMP TABLE related_to_2 AS
WITH RECURSIVE walk(issue_id, depth) AS (
    SELECT 2::bigint, 0
    UNION ALL
    SELECT r.related_issue_id, w.depth + 1
    FROM related_issue AS r JOIN walk AS w ON r.issue_id = w.issue_id
    WHERE w.depth < 3
) CYCLE issue_id SET is_cycle USING path
SELECT issue_id, depth, is_cycle, path::text AS path_text,
       row_number() OVER (ORDER BY path) AS ord
FROM walk;
SELECT string_agg(issue_id::text, ',' ORDER BY ord) FILTER (WHERE NOT is_cycle) = '2,5,3'
   AND string_agg(path_text, ' ' ORDER BY ord) FILTER (WHERE NOT is_cycle)
       = '{(2)} {(2),(5)} {(2),(5),(3)}'
   AND count(*) FILTER (WHERE is_cycle) = 2 AS valid
FROM related_to_2 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A self-loop is rejected by the row check.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (1, 3, 3, 'blocks');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND strpos(:'rejected_message', 'issue_link_no_self_loop') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The reverse spelling of an existing symmetric link is rejected, not duplicated.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (1, 5, 2, 'relates');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND strpos(:'rejected_message', 'issue_link_relates_canonical') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Writers normalize the pair; the canonical spelling then hits the key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind)
VALUES (1, least(5, 2), greatest(5, 2), 'relates');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505'
   AND strpos(:'rejected_message', 'issue_link_pkey') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An edge between projects is rejected by the composite foreign key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (1, 4, 6, 'blocks');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503'
   AND strpos(:'rejected_message', 'issue_link_to_fk') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Closing a cycle through the diamond is rejected by the trigger.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (1, 4, 1, 'blocks');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND strpos(:'rejected_message', 'blocking link 4 -> 1 would close a cycle') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Retargeting an existing edge is checked too.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE issue_link SET from_issue_id = 4, to_issue_id = 2
WHERE from_issue_id = 5 AND to_issue_id = 4 AND kind = 'blocks';
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND strpos(:'rejected_message', 'blocking link 4 -> 2 would close a cycle') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The check walks only blocking links: 4 relates to 1 while 1 blocks 4.
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (1, 1, 4, 'relates');

-- The race, emulated. Project 2 has B -> C and D -> A.
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES
    (2, 7, 8, 'blocks'), (2, 9, 6, 'blocks');

-- Each new edge passes the check on its own against the same graph.
SAVEPOINT alone;
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (2, 6, 7, 'blocks');
ROLLBACK TO SAVEPOINT alone;
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (2, 8, 9, 'blocks');
ROLLBACK TO SAVEPOINT alone;

-- Two sessions that both checked the old graph would store both edges.
-- Keys, foreign keys and checks accept the result; only a traversal sees the cycle.
SAVEPOINT unchecked;
ALTER TABLE issue_link DISABLE TRIGGER issue_link_acyclic;
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES
    (2, 6, 7, 'blocks'), (2, 8, 9, 'blocks');
SELECT count(*) = 1 AND min(path::text) = '{(6),(7),(8),(9),(6)}' AS valid
FROM (
    WITH RECURSIVE walk(issue_id) AS (
        SELECT 6::bigint
        UNION ALL
        SELECT l.to_issue_id
        FROM issue_link AS l JOIN walk AS w ON l.from_issue_id = w.issue_id
        WHERE l.kind = 'blocks'
    ) CYCLE issue_id SET is_cycle USING path
    SELECT path FROM walk WHERE is_cycle
) AS found \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
ROLLBACK TO SAVEPOINT unchecked;

-- Serialized, the second edge is checked against the first and rejected.
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (2, 6, 7, 'blocks');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES (2, 8, 9, 'blocks');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND strpos(:'rejected_message', 'blocking link 8 -> 9 would close a cycle') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- One statement inserting both halves of a cycle is rejected too: a BEFORE ROW
-- trigger sees the rows the same statement inserted earlier.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO issue_link (project_id, from_issue_id, to_issue_id, kind) VALUES
    (1, 5, 3, 'blocks'), (1, 3, 5, 'blocks');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND strpos(:'rejected_message', 'blocking link 3 -> 5 would close a cycle') > 0 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Deleting a node removes its edges; deleting an edge never needs the cycle check.
DELETE FROM issue WHERE issue_id = 5;
SELECT (SELECT count(*) FROM issue_link WHERE 5 IN (from_issue_id, to_issue_id)) = 0
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
