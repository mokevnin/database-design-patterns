-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f canonical-value.sql in an empty database.
-- The duplicate-key and collision errors are intentional and checked by SQLSTATE.
-- The nondeterministic-collation variant needs a server built with ICU.
\set ON_ERROR_STOP on
BEGIN;

-- One canonicalization rule, named and versioned in the schema.
-- pg_unicode_fast pins full Unicode case folding regardless of the database default.
CREATE FUNCTION canonical_email_v1(raw text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
RETURN normalize(casefold(normalize(raw, NFD) COLLATE pg_unicode_fast), NFC);

CREATE TABLE app_user (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL,
    email_key text GENERATED ALWAYS AS (canonical_email_v1(email)) STORED,
    CONSTRAINT app_user_email_key UNIQUE (email_key),
    CONSTRAINT app_user_email_shape CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+$')
);

INSERT INTO app_user (email) VALUES ('Bob@Example.COM') RETURNING user_id, email, email_key;
INSERT INTO app_user (email) VALUES (U&'J\00FCrgen@example.de') RETURNING user_id, email, email_key;
-- user 1 keeps 'Bob@Example.COM' and has key 'bob@example.com'.

SELECT count(*) = 2 AS stored_as_entered
FROM app_user
WHERE email IN ('Bob@Example.COM', U&'J\00FCrgen@example.de') \gset
\if :stored_as_entered
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Same address in a different case.
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO app_user (email) VALUES ('bob@example.com');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Same address with a decomposed u-umlaut and different case.
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO app_user (email) VALUES (U&'JU\0308RGEN@EXAMPLE.DE');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Full folding is a policy decision: sharp s folds to "ss".
SELECT canonical_email_v1('STRAßE@example.de') = 'strasse@example.de' AS full_folding \gset
\if :full_folding
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Idempotent sign-up: the conflict target is the canonical column.
INSERT INTO app_user (email) VALUES ('BOB@example.com')
ON CONFLICT (email_key) DO NOTHING
RETURNING user_id;
-- No row returned: the address is already registered.

-- Lookup canonicalizes the input with the same function.
SELECT user_id, email FROM app_user
WHERE email_key = canonical_email_v1('bob@EXAMPLE.com');
-- user_id = 1, email = 'Bob@Example.COM'.

-- The canonical lookup can use the unique index (seq scans disabled for a tiny table).
DO $$
DECLARE
    line text;
    found boolean := false;
BEGIN
    SET LOCAL enable_seqscan = off;
    FOR line IN EXECUTE
        'EXPLAIN SELECT user_id FROM app_user '
        'WHERE email_key = canonical_email_v1(''bob@EXAMPLE.com'')'
    LOOP
        found := found OR line LIKE '%app_user_email_key%';
    END LOOP;
    RESET enable_seqscan;
    ASSERT found, 'lookup does not use app_user_email_key';
END
$$;

-- Variant: the equality rule lives in a nondeterministic collation.
CREATE COLLATION case_insensitive (
    provider = icu, locale = 'und-u-ks-level2', deterministic = false
);
CREATE TABLE ci_user (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text COLLATE case_insensitive NOT NULL,
    CONSTRAINT ci_user_email_key UNIQUE (email)
);
INSERT INTO ci_user (email) VALUES ('Bob@Example.COM');

SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO ci_user (email) VALUES ('bob@example.com');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Migration: a legacy table whose plain unique constraint let variants in.
CREATE TABLE legacy_user (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE
);
INSERT INTO legacy_user (email)
VALUES ('ann@example.com'), ('Ann@Example.com'), ('carl@example.com');

-- Collision report before enforcing the canonical rule.
SELECT canonical_email_v1(email) AS email_key,
       array_agg(user_id ORDER BY user_id) AS user_ids
FROM legacy_user
GROUP BY 1
HAVING count(*) > 1;
-- One group: ann@example.com -> {1,2}.

SAVEPOINT expected_error;
\set ON_ERROR_STOP off
CREATE UNIQUE INDEX legacy_user_email_key_idx
    ON legacy_user (canonical_email_v1(email));
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Resolve the collision (here: user 2 was a duplicate sign-up), then enforce.
DELETE FROM legacy_user WHERE user_id = 2;
CREATE UNIQUE INDEX legacy_user_email_key_idx
    ON legacy_user (canonical_email_v1(email));

SELECT count(*) = 2 AS migrated FROM legacy_user \gset
\if :migrated
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
