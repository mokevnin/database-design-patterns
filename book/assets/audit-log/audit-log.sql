-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f audit-log.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
-- Requires CREATEROLE and permission to SET ROLE; the lab role rolls back.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA audit_example;
REVOKE ALL ON SCHEMA audit_example FROM PUBLIC;
CREATE TABLE audit_example.account (
    account_id bigint PRIMARY KEY,
    credit_limit numeric(12,2) NOT NULL CHECK (credit_limit >= 0)
);
CREATE TABLE audit_example.audit_event (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint NOT NULL,
    action text NOT NULL CHECK (action = 'change_limit'),
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL,
    actor text NOT NULL CHECK (btrim(actor) <> ''),
    database_login text NOT NULL,
    reason text NOT NULL CHECK (btrim(reason) <> ''),
    request_id uuid NOT NULL,
    before_data jsonb NOT NULL,
    after_data jsonb NOT NULL
);
CREATE INDEX audit_event_account_idx
    ON audit_example.audit_event (account_id, event_id);
CREATE INDEX audit_event_request_idx ON audit_example.audit_event (request_id);
CREATE FUNCTION audit_example.change_limit(
    p_account_id bigint, p_limit numeric, p_actor text,
    p_reason text, p_request_id uuid, p_occurred_at timestamptz
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    before_row audit_example.account%ROWTYPE;
    after_row audit_example.account%ROWTYPE;
BEGIN
    SELECT * INTO STRICT before_row FROM audit_example.account
    WHERE account_id = p_account_id FOR UPDATE;
    UPDATE audit_example.account SET credit_limit = p_limit
    WHERE account_id = p_account_id RETURNING * INTO after_row;
    INSERT INTO audit_example.audit_event
        (account_id, action, occurred_at, recorded_at, actor, database_login,
         reason, request_id, before_data, after_data)
    VALUES (p_account_id, 'change_limit', p_occurred_at, clock_timestamp(),
            p_actor, session_user, p_reason, p_request_id,
            to_jsonb(before_row), to_jsonb(after_row));
END;
$$;
REVOKE ALL ON FUNCTION audit_example.change_limit(bigint, numeric, text, text, uuid, timestamptz)
    FROM PUBLIC;
CREATE ROLE audit_example_app NOLOGIN;
GRANT USAGE ON SCHEMA audit_example TO audit_example_app;
GRANT SELECT ON audit_example.account, audit_example.audit_event TO audit_example_app;
GRANT EXECUTE ON FUNCTION audit_example.change_limit(bigint, numeric, text, text, uuid, timestamptz)
    TO audit_example_app;

INSERT INTO audit_example.account VALUES (1, 1000);
SET ROLE audit_example_app;
SELECT audit_example.change_limit(
    1, 1500, 'user:42', 'Approved review',
    '550e8400-e29b-41d4-a716-446655440000', '2026-03-01 12:00+00'
);
SELECT actor, reason, before_data ->> 'credit_limit' AS old_limit,
       after_data ->> 'credit_limit' AS new_limit
FROM audit_example.audit_event WHERE account_id = 1 ORDER BY event_id;

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE audit_example.audit_event SET reason = 'Rewritten' WHERE event_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '42501' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

SAVEPOINT missing_context;
\set ON_ERROR_STOP off
SELECT audit_example.change_limit(
    1, 2000, 'user:42', '',
    '550e8400-e29b-41d4-a716-446655440001', '2026-03-02 12:00+00'
);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT missing_context;
SELECT :'rejected_state' = '23514'
    AND (SELECT credit_limit = 1500 FROM audit_example.account WHERE account_id = 1)
    AND (SELECT count(*) = 1 FROM audit_example.audit_event) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
RESET ROLE;

ROLLBACK;
