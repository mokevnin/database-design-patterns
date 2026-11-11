-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f association-table.sql in an empty database.
-- Expected errors are intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on

CREATE TABLE project (
    project_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE person (
    person_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE project_member (
    project_id bigint NOT NULL REFERENCES project (project_id)
        ON DELETE CASCADE,
    person_id bigint NOT NULL REFERENCES person (person_id),
    member_role text NOT NULL CHECK (member_role IN ('reader', 'editor')),
    joined_on date NOT NULL,
    CONSTRAINT project_member_pkey PRIMARY KEY (project_id, person_id)
);
CREATE INDEX project_member_person_idx
    ON project_member (person_id, project_id);
INSERT INTO project VALUES (10, 'Catalog'), (20, 'Checkout');
INSERT INTO person VALUES (1, 'Ada'), (2, 'Lin');
INSERT INTO project_member VALUES
    (10, 1, 'editor', DATE '2026-11-10'),
    (10, 2, 'reader', DATE '2026-11-10'),
    (20, 1, 'reader', DATE '2026-11-10');
SELECT p.name, m.member_role
FROM project_member AS m JOIN person AS p USING (person_id)
WHERE m.project_id = 10 ORDER BY m.person_id;
SELECT p.name FROM project_member AS m
JOIN project AS p USING (project_id)
WHERE m.person_id = 1 ORDER BY m.project_id;
UPDATE project_member SET member_role = 'editor'
WHERE project_id = 10 AND person_id = 2;

DO $$ BEGIN
    ASSERT (SELECT member_role = 'editor' FROM project_member WHERE project_id = 10 AND person_id = 2);
END $$;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
INSERT INTO project_member VALUES
    (10, 1, 'reader', DATE '2026-11-11');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
INSERT INTO project_member VALUES (999, 1, 'reader', DATE '2026-11-10');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
DELETE FROM person WHERE person_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
DELETE FROM project_member WHERE project_id = 20 AND person_id = 1;
DELETE FROM project WHERE project_id = 10;
SELECT count(*) FROM project_member;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM project_member) AND (SELECT count(*) = 2 FROM person);
END $$;
