-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f hashed-secret.sql in an empty database.
-- The rejected-plaintext, short-hash and second-open-token errors are intentional
-- and checked by SQLSTATE.
--
-- Lab only: sha256() runs in SQL here so the script is self-contained.
-- In an application, generate tokens and compute every hash in the application
-- and send only the hash, so the secret never reaches the server or its logs.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE app_user (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email text NOT NULL UNIQUE
);

-- Passwords: a slow, salted hash computed by the application, stored as a
-- self-describing string. The CHECK accepts the current Argon2id PHC format
-- and the legacy bcrypt format, and rejects anything that looks like plaintext.
CREATE TABLE user_password (
    user_id bigint PRIMARY KEY REFERENCES app_user (user_id) ON DELETE CASCADE,
    password_hash text NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_password_hash_format CHECK (
        password_hash ~ '^\$argon2id\$v=19\$m=[0-9]+,t=[0-9]+,p=[0-9]+\$[A-Za-z0-9+/]{11,}\$[A-Za-z0-9+/]{16,}$'
        OR password_hash ~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
    )
);

INSERT INTO app_user (email) VALUES ('ann@example.com'), ('bob@example.com');

-- Produced by the Argon2 reference CLI with m=19456 KiB, t=2, p=1.
-- The salt is fixed only to make the lab reproducible; real salts are random.
INSERT INTO user_password (user_id, password_hash) VALUES
    (1, '$argon2id$v=19$m=19456,t=2,p=1$TmFDbC1sYWItc2FsdDE2$aiyNlDE5WAGTEP4NbEpm4hTRDp6wSN4VBdarWkjulR0'),
    (2, '$2a$10$WiGZyfJknCvhCUDSXlXHZeO12xOV4BCL/j82216.L6iJPupGmD.FK');

-- A code path that forgot to hash is rejected.
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
UPDATE user_password SET password_hash = 'correct horse battery staple'
WHERE user_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- Users whose hash should be upgraded at their next successful login.
SELECT user_id FROM user_password
WHERE password_hash NOT LIKE '$argon2id$v=19$m=19456,t=2,p=1$%';
-- user_id = 2 (legacy bcrypt).

SELECT array_agg(user_id) = ARRAY[2]::bigint[] AS legacy_found
FROM user_password
WHERE password_hash NOT LIKE '$argon2id$v=19$m=19456,t=2,p=1$%' \gset
\if :legacy_found
\else
    \quit 1
\endif

-- Rehash on login: replace only the hash that was verified, so a concurrent
-- password change is not overwritten.
WITH upgraded AS (
    UPDATE user_password
    SET password_hash = '$argon2id$v=19$m=19456,t=2,p=1$TmFDbC1sYWItc2FsdDE2$aiyNlDE5WAGTEP4NbEpm4hTRDp6wSN4VBdarWkjulR0',
        changed_at = now()
    WHERE user_id = 2
      AND password_hash = '$2a$10$WiGZyfJknCvhCUDSXlXHZeO12xOV4BCL/j82216.L6iJPupGmD.FK'
    RETURNING user_id
)
SELECT count(*) = 1 AS rehashed FROM upgraded \gset
\if :rehashed
\else
    \quit 1
\endif

-- API keys: a high-entropy random token, stored as its SHA-256 digest.
-- The digest is the lookup key; the hint is only for recognizing the key in a UI.
CREATE TABLE api_key (
    api_key_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint NOT NULL,
    token_hash bytea NOT NULL,
    display_hint text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    revoked_at timestamptz,
    CONSTRAINT api_key_token_hash_key UNIQUE (token_hash),
    CONSTRAINT api_key_token_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT api_key_display_hint_shape CHECK (display_hint ~ '^dbp_[a-z0-9_]{4}$')
);

-- A fixed test token; a real one comes from a CSPRNG and is shown to the user once.
\set token 'dbp_example_not_a_real_key_000001'

INSERT INTO api_key (account_id, token_hash, display_hint)
VALUES (42, sha256(convert_to(:'token', 'UTF8')), left(:'token', 8))
RETURNING api_key_id, display_hint;

-- Storing the token itself instead of its digest is rejected by the length check.
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO api_key (account_id, token_hash, display_hint)
VALUES (42, convert_to(:'token', 'UTF8'), left(:'token', 8));
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- Authenticate a request: hash the presented token and look it up.
SELECT account_id FROM api_key
WHERE token_hash = sha256(convert_to(:'token', 'UTF8'))
  AND revoked_at IS NULL
  AND (expires_at IS NULL OR expires_at > now());
-- account_id = 42.

UPDATE api_key SET revoked_at = now()
WHERE token_hash = sha256(convert_to(:'token', 'UTF8'));

SELECT count(*) = 0 AS revoked FROM api_key
WHERE token_hash = sha256(convert_to(:'token', 'UTF8'))
  AND revoked_at IS NULL
  AND (expires_at IS NULL OR expires_at > now()) \gset
\if :revoked
\else
    \quit 1
\endif

-- Password reset: a single-use, expiring token, at most one open per user.
CREATE TABLE password_reset (
    reset_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES app_user (user_id) ON DELETE CASCADE,
    token_hash bytea NOT NULL,
    expires_at timestamptz NOT NULL,
    closed_at timestamptz,
    closed_reason text,
    CONSTRAINT password_reset_token_hash_key UNIQUE (token_hash),
    CONSTRAINT password_reset_token_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT password_reset_closed_pair CHECK ((closed_at IS NULL) = (closed_reason IS NULL)),
    CONSTRAINT password_reset_closed_reason CHECK (closed_reason IN ('used', 'superseded', 'expired'))
);
CREATE UNIQUE INDEX password_reset_one_open
    ON password_reset (user_id) WHERE closed_at IS NULL;

\set reset1 'rst_5a1c9e3f7b2d4c6e8f0a1b2c3d4e5f60'
\set reset2 'rst_0b7d2f4a6c8e1a3c5e7f9b1d3f5a7c9e'

INSERT INTO password_reset (user_id, token_hash, expires_at)
VALUES (1, sha256(convert_to(:'reset1', 'UTF8')), now() + interval '30 minutes');

-- A second open token for the same user is rejected...
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO password_reset (user_id, token_hash, expires_at)
VALUES (1, sha256(convert_to(:'reset2', 'UTF8')), now() + interval '30 minutes');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- ...so issuing a new one supersedes the old one in the same transaction.
UPDATE password_reset SET closed_at = now(), closed_reason = 'superseded'
WHERE user_id = 1 AND closed_at IS NULL;
INSERT INTO password_reset (user_id, token_hash, expires_at)
VALUES (1, sha256(convert_to(:'reset2', 'UTF8')), now() + interval '30 minutes');

-- Consuming is one conditional UPDATE: only the first attempt gets a row.
WITH consumed AS (
    UPDATE password_reset SET closed_at = now(), closed_reason = 'used'
    WHERE token_hash = sha256(convert_to(:'reset2', 'UTF8'))
      AND closed_at IS NULL
      AND expires_at > now()
    RETURNING user_id
)
SELECT count(*) = 1 AS first_use FROM consumed \gset
\if :first_use
\else
    \quit 1
\endif

WITH consumed AS (
    UPDATE password_reset SET closed_at = now(), closed_reason = 'used'
    WHERE token_hash = sha256(convert_to(:'reset2', 'UTF8'))
      AND closed_at IS NULL
      AND expires_at > now()
    RETURNING user_id
)
SELECT count(*) = 0 AS second_use_refused FROM consumed \gset
\if :second_use_refused
\else
    \quit 1
\endif

-- The superseded token no longer works either.
SELECT count(*) = 0 AS old_token_refused FROM password_reset
WHERE token_hash = sha256(convert_to(:'reset1', 'UTF8'))
  AND closed_at IS NULL
  AND expires_at > now() \gset
\if :old_token_refused
\else
    \quit 1
\endif

ROLLBACK;
