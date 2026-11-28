-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f permission-grant.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA grant_example;
SET LOCAL search_path = grant_example, public;

-- Scope tables: a project always lies in one organization.
CREATE TABLE organization (
    org_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE project (
    project_id bigint PRIMARY KEY,
    org_id bigint NOT NULL REFERENCES organization (org_id),
    name text NOT NULL,
    UNIQUE (org_id, project_id)
);
CREATE TABLE app_user (
    user_id bigint PRIMARY KEY,
    display_name text NOT NULL
);

-- The action vocabulary, the roles and the permissions each role bundles.
CREATE TABLE permission (
    permission_code text PRIMARY KEY
);
CREATE TABLE role (
    role_code text PRIMARY KEY,
    duty_group text NOT NULL,
    UNIQUE (role_code, duty_group)
);
CREATE TABLE role_permission (
    role_code text NOT NULL REFERENCES role (role_code),
    permission_code text NOT NULL REFERENCES permission (permission_code),
    PRIMARY KEY (role_code, permission_code)
);

-- Who holds which role, in which scope, for which period, granted by whom.
CREATE TABLE role_assignment (
    assignment_id bigint PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES app_user (user_id),
    role_code text NOT NULL,
    duty_group text NOT NULL,
    org_id bigint NOT NULL REFERENCES organization (org_id),
    project_id bigint,
    valid_during tstzrange NOT NULL,
    granted_by bigint NOT NULL REFERENCES app_user (user_id),
    revoked_by bigint REFERENCES app_user (user_id),
    CONSTRAINT assignment_role_fkey FOREIGN KEY (role_code, duty_group)
        REFERENCES role (role_code, duty_group) ON UPDATE CASCADE,
    CONSTRAINT assignment_project_fkey FOREIGN KEY (org_id, project_id)
        REFERENCES project (org_id, project_id),
    CONSTRAINT assignment_period_check
        CHECK (NOT isempty(valid_during) AND NOT lower_inf(valid_during)),
    CONSTRAINT assignment_revocation_check
        CHECK (revoked_by IS NULL OR NOT upper_inf(valid_during)),
    CONSTRAINT separation_of_duty EXCLUDE USING gist (
        org_id WITH =, user_id WITH =, duty_group WITH =,
        role_code WITH <>, valid_during WITH &&)
);

-- Every grant that gives a user a permission on a project at an instant, with its reason.
CREATE FUNCTION permission_source(p_user bigint, p_permission text, p_project bigint, p_at timestamptz)
RETURNS TABLE (assignment_id bigint, role_code text, scope text)
LANGUAGE sql STABLE
BEGIN ATOMIC
    SELECT a.assignment_id, a.role_code,
           CASE WHEN a.project_id IS NULL THEN 'organization' ELSE 'project' END
    FROM project AS p
    JOIN role_assignment AS a
      ON a.org_id = p.org_id
     AND (a.project_id IS NULL OR a.project_id = p.project_id)
    JOIN role_permission AS rp
      ON rp.role_code = a.role_code
    WHERE p.project_id = p_project
      AND a.user_id = p_user
      AND rp.permission_code = p_permission
      AND a.valid_during @> p_at;
END;
CREATE FUNCTION has_permission(p_user bigint, p_permission text, p_project bigint, p_at timestamptz)
RETURNS boolean
LANGUAGE sql STABLE
RETURN EXISTS (SELECT FROM permission_source(p_user, p_permission, p_project, p_at));

INSERT INTO organization VALUES (1, 'Acme'), (2, 'Globex');
INSERT INTO project VALUES (10, 1, 'Apollo'), (11, 1, 'Borealis'), (20, 2, 'Cosmos');
INSERT INTO app_user VALUES (1, 'Ada'), (2, 'Ben'), (3, 'Cy'), (9, 'Admin');
INSERT INTO permission VALUES
    ('project.read'), ('project.edit'), ('expense.submit'), ('expense.approve');
INSERT INTO role VALUES
    ('viewer', 'viewer'), ('editor', 'editor'),
    ('requester', 'expense'), ('approver', 'expense');
INSERT INTO role_permission VALUES
    ('viewer', 'project.read'),
    ('editor', 'project.read'), ('editor', 'project.edit'),
    ('requester', 'project.read'), ('requester', 'expense.submit'),
    ('approver', 'project.read'), ('approver', 'expense.approve');

-- Ada edits every Acme project; Ben requests on Apollo; Cy views Borealis until March.
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT v.assignment_id, v.user_id, r.role_code, r.duty_group, v.org_id, v.project_id, v.valid_during::tstzrange, 9
FROM (VALUES
    (100, 1, 'editor', 1, NULL, '[2026-01-01,)'),
    (101, 2, 'requester', 1, 10, '[2026-01-01,)'),
    (102, 3, 'viewer', 1, 11, '[2026-01-01,2026-03-01)')
) AS v (assignment_id, user_id, role_code, org_id, project_id, valid_during)
JOIN role AS r USING (role_code);

-- An organization-wide grant is inherited by every project of that organization only.
SELECT has_permission(1, 'project.edit', 11, '2026-02-01')
   AND NOT has_permission(1, 'project.edit', 20, '2026-02-01')
   AND has_permission(2, 'expense.submit', 10, '2026-02-01')
   AND NOT has_permission(2, 'expense.submit', 11, '2026-02-01')
   AND NOT has_permission(2, 'expense.approve', 10, '2026-02-01')
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The check explains itself: Ada edits Borealis through her organization editor grant.
SELECT (SELECT array_agg(assignment_id::text || ':' || role_code || ':' || scope)
        FROM permission_source(1, 'project.edit', 11, '2026-02-01'))
       = ARRAY['100:editor:organization'] AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A time-bound grant ends at its upper bound: the period is half-open.
SELECT has_permission(3, 'project.read', 11, '2026-02-28 23:59:59')
   AND NOT has_permission(3, 'project.read', 11, '2026-03-01 00:00:00') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Approver and requester share a duty group; editor does not conflict with either.
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 103, 1, role_code, duty_group, 1, NULL, '[2026-01-01,)', 9
FROM role WHERE role_code = 'approver';

-- The same role on two projects of one organization is allowed.
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 104, 2, role_code, duty_group, 1, 11, '[2026-01-01,)', 9
FROM role WHERE role_code = 'requester';

-- Reverse lookup: who can approve expenses on Apollo on February 1?
SELECT (SELECT array_agg(u.display_name ORDER BY u.user_id)
        FROM app_user AS u
        WHERE has_permission(u.user_id, 'expense.approve', 10, '2026-02-01'))
       = ARRAY['Ada'] AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Requester and approver on the same project are rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 105, 2, role_code, duty_group, 1, 10, '[2026-02-01,)', 9
FROM role WHERE role_code = 'approver';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An organization approver cannot become requester on one of its projects either.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 106, 1, role_code, duty_group, 1, 10, '[2026-02-01,)', 9
FROM role WHERE role_code = 'requester';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- In another organization the duties do not conflict.
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 107, 2, role_code, duty_group, 2, 20, '[2026-01-01,)', 9
FROM role WHERE role_code = 'approver';

-- The caller cannot put a role into another duty group.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
VALUES (108, 2, 'approver', 'approver', 1, 10, '[2026-02-01,)', 9);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A project scope must belong to the assignment's organization.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 109, 3, role_code, duty_group, 1, 20, '[2026-01-01,)', 9
FROM role WHERE role_code = 'viewer';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- With no project, the composite reference is skipped; the organization reference still applies.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 112, 3, role_code, duty_group, 99, NULL, '[2026-01-01,)', 9
FROM role WHERE role_code = 'viewer';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Revocation closes the period at the revocation instant and records who revoked.
UPDATE role_assignment
SET valid_during = tstzrange(lower(valid_during), '2026-06-01'), revoked_by = 9
WHERE assignment_id IN (101, 104) AND valid_during @> TIMESTAMPTZ '2026-06-01';
SELECT has_permission(2, 'expense.submit', 10, '2026-05-31')
   AND NOT has_permission(2, 'expense.submit', 10, '2026-06-01') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- After revocation Ben may become approver, but not backdated into the requester period.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 110, 2, role_code, duty_group, 1, NULL, '[2026-05-01,)', 9
FROM role WHERE role_code = 'approver';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 110, 2, role_code, duty_group, 1, NULL, '[2026-06-01,)', 9
FROM role WHERE role_code = 'approver';
SELECT has_permission(2, 'expense.approve', 11, '2026-06-01')
   AND NOT has_permission(2, 'expense.submit', 11, '2026-06-01') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A grant that has not started cannot be shortened to nothing; delete it instead.
INSERT INTO role_assignment
    (assignment_id, user_id, role_code, duty_group, org_id, project_id, valid_during, granted_by)
SELECT 111, 3, role_code, duty_group, 1, 11, '[2026-09-01,2026-12-01)', 9
FROM role WHERE role_code = 'viewer';
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE role_assignment
SET valid_during = tstzrange(lower(valid_during), '2026-09-01'), revoked_by = 9
WHERE assignment_id = 111;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
DELETE FROM role_assignment WHERE assignment_id = 111;

-- A revocation marker on an open-ended period is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE role_assignment SET revoked_by = 9 WHERE assignment_id = 100;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Moving a role into a duty group is checked against existing grants through the cascade.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE role SET duty_group = 'expense' WHERE role_code = 'editor';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An exclusion constraint cannot be added NOT VALID: adding it checks every existing row.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
ALTER TABLE role_assignment ADD CONSTRAINT assignment_unique_grant EXCLUDE USING gist (
    org_id WITH =, user_id WITH =, role_code WITH =,
    (coalesce(project_id, 0)) WITH =, valid_during WITH &&) NOT VALID;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '0A000' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
