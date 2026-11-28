-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f guessable-links.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE and message;
-- a failed check evaluates 1 / 0, so psql stops with a non-zero exit status.
-- The literal tokens are deliberately non-random lab values; a real share token
-- is at least 128 bits from a CSPRNG, generated and hashed in the application.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA guessable_links_example;
SET LOCAL search_path TO guessable_links_example;

------------------------------------------------------------------------------
-- Before: the share link is a deterministic function of the document ID.
------------------------------------------------------------------------------
CREATE TABLE app_user (
    user_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE document (
    document_id bigint PRIMARY KEY,
    owner_id bigint NOT NULL REFERENCES app_user (user_id),
    title text NOT NULL,
    is_shared boolean NOT NULL DEFAULT false,
    share_key text UNIQUE
);

INSERT INTO app_user VALUES (1, 'Alice'), (2, 'Bob');
INSERT INTO document (document_id, owner_id, title, is_shared) VALUES
    (1040, 1, 'Board minutes', false),
    (1041, 1, 'Q3 forecast', true),
    (1042, 2, 'Salary review', true),
    (1043, 2, 'Offer letter', true);

-- Three popular "obfuscations" of the same integer.
UPDATE document SET share_key = CASE document_id
    WHEN 1041 THEN md5(document_id::text)
    WHEN 1042 THEN encode(sha256(convert_to(document_id::text, 'UTF8')), 'hex')
    WHEN 1043 THEN encode(convert_to(document_id::text, 'UTF8'), 'base64')
    ELSE md5(document_id::text)
END;
SELECT share_key = 'MTA0Mw==' AS valid FROM document WHERE document_id = 1043 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The public share endpoint: possession of the key is the only check.
SELECT count(*) = 1 AS valid FROM document
WHERE share_key = md5('1041') AND is_shared \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The attacker recomputes every candidate key; no database access is needed,
-- this join only counts what a loop of HTTP requests would find.
SELECT count(DISTINCT d.document_id) = 3
   AND count(DISTINCT d.owner_id) = 2 AS valid
FROM generate_series(1, 5000) AS guess(n)
CROSS JOIN LATERAL (VALUES
    (md5(guess.n::text)),
    (encode(sha256(convert_to(guess.n::text, 'UTF8')), 'hex')),
    (encode(convert_to(guess.n::text, 'UTF8'), 'base64'))
) AS candidate(share_key)
JOIN document AS d USING (share_key)
WHERE d.is_shared \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- One key per document: the owner cannot revoke one recipient's access
-- without unsharing the document for everyone.
SELECT count(*) = 0 AS valid FROM (
    SELECT share_key FROM document GROUP BY share_key HAVING count(*) > 1
) AS dup \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

------------------------------------------------------------------------------
-- After: a capability token per share, stored as a digest.
------------------------------------------------------------------------------
ALTER TABLE document
    ADD COLUMN public_id uuid NOT NULL UNIQUE DEFAULT uuidv4();

CREATE TABLE document_share (
    share_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id bigint NOT NULL REFERENCES document (document_id) ON DELETE CASCADE,
    token_hash bytea NOT NULL,
    scope text NOT NULL DEFAULT 'read',
    origin text NOT NULL DEFAULT 'issued',
    created_by bigint NOT NULL REFERENCES app_user (user_id),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoked_by bigint REFERENCES app_user (user_id),
    CONSTRAINT document_share_token_hash_key UNIQUE (token_hash),
    CONSTRAINT document_share_token_hash_length CHECK (octet_length(token_hash) = 32),
    CONSTRAINT document_share_scope CHECK (scope IN ('read', 'comment')),
    CONSTRAINT document_share_origin CHECK (origin IN ('issued', 'legacy')),
    CONSTRAINT document_share_lifetime CHECK (
        expires_at > created_at AND expires_at <= created_at + interval '2160 hours'),
    CONSTRAINT document_share_revocation CHECK ((revoked_at IS NULL) = (revoked_by IS NULL))
);
CREATE INDEX document_share_document_idx ON document_share (document_id);

-- Why the cap is in hours: '90 days' follows the session zone across a DST change.
SET LOCAL TIME ZONE 'Europe/Berlin';
SELECT TIMESTAMPTZ '2026-03-01 12:00+01' + interval '90 days'
    <> TIMESTAMPTZ '2026-03-01 12:00+01' + interval '2160 hours' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SET LOCAL TIME ZONE 'UTC';

CREATE TABLE document_share_access (
    access_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    share_id bigint NOT NULL REFERENCES document_share (share_id) ON DELETE CASCADE,
    accessed_at timestamptz NOT NULL DEFAULT now(),
    client_addr inet
);
CREATE INDEX document_share_access_share_idx ON document_share_access (share_id, accessed_at);

-- Migration step 2: issue a new token for every existing share.
-- The application generates each token, stores its digest and shows the new
-- link to the creator once.
INSERT INTO document_share (document_id, token_hash, created_by, expires_at)
SELECT d.document_id, sha256(convert_to(t.token, 'UTF8')), d.owner_id,
       now() + interval '30 days'
FROM document AS d
JOIN (VALUES
    (1041, 'shr_lab_forecast_for_colleague_not_random'),
    (1042, 'shr_lab_salary_review_not_random'),
    (1043, 'shr_lab_offer_letter_not_random')
) AS t (document_id, token) USING (document_id)
WHERE d.is_shared;

-- Migration step 3 (optional): keep old URLs for a short, logged window.
-- The old key is treated as a token string: its digest goes into the same table.
INSERT INTO document_share (document_id, token_hash, origin, created_by, expires_at)
SELECT document_id, sha256(convert_to(share_key, 'UTF8')), 'legacy', owner_id,
       now() + interval '14 days'
FROM document WHERE is_shared;

SELECT count(*) FILTER (WHERE origin = 'issued') = 3
   AND count(*) FILTER (WHERE origin = 'legacy') = 3 AS valid
FROM document_share \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A second, independent link to the same document for another recipient.
INSERT INTO document_share (document_id, token_hash, scope, created_by, expires_at)
VALUES (1041, sha256(convert_to('shr_lab_forecast_for_client_not_random', 'UTF8')),
        'comment', 1, now() + interval '7 days');

-- An expired link: created ten days ago, valid for nine.
INSERT INTO document_share (document_id, token_hash, created_by, created_at, expires_at)
VALUES (1042, sha256(convert_to('shr_lab_expired_not_random', 'UTF8')), 2,
        now() - interval '10 days', now() - interval '1 day');

-- The lookup by digest checks expiry and revocation and logs the access in one statement.
CREATE TEMPORARY TABLE lookup_result (title text, scope text);
WITH hit AS (
    SELECT s.share_id, s.document_id, s.scope
    FROM document_share AS s
    WHERE s.token_hash = sha256(convert_to('shr_lab_forecast_for_colleague_not_random', 'UTF8'))
      AND s.revoked_at IS NULL
      AND s.expires_at > now()
), logged AS (
    INSERT INTO document_share_access (share_id, client_addr)
    SELECT share_id, inet '203.0.113.7' FROM hit
)
INSERT INTO lookup_result
SELECT d.title, hit.scope FROM hit JOIN document AS d USING (document_id);
SELECT (SELECT count(*) = 1 FROM lookup_result)
   AND (SELECT title = 'Q3 forecast' AND scope = 'read' FROM lookup_result)
   AND (SELECT count(*) = 1 FROM document_share_access
        WHERE client_addr = inet '203.0.113.7') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The expired link resolves to nothing.
SELECT count(*) = 0 AS valid FROM document_share
WHERE token_hash = sha256(convert_to('shr_lab_expired_not_random', 'UTF8'))
  AND revoked_at IS NULL AND expires_at > now() \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Revoking one link leaves the other link to the same document working.
UPDATE document_share SET revoked_at = now(), revoked_by = 1
WHERE token_hash = sha256(convert_to('shr_lab_forecast_for_colleague_not_random', 'UTF8'))
  AND revoked_at IS NULL;
SELECT
    (SELECT count(*) = 0 FROM document_share
     WHERE token_hash = sha256(convert_to('shr_lab_forecast_for_colleague_not_random', 'UTF8'))
       AND revoked_at IS NULL AND expires_at > now())
AND (SELECT count(*) = 1 FROM document_share
     WHERE token_hash = sha256(convert_to('shr_lab_forecast_for_client_not_random', 'UTF8'))
       AND revoked_at IS NULL AND expires_at > now()) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Revoking again is harmless: the guarded UPDATE touches no row.
WITH again AS (
    UPDATE document_share SET revoked_at = now(), revoked_by = 1
    WHERE token_hash = sha256(convert_to('shr_lab_forecast_for_colleague_not_random', 'UTF8'))
      AND revoked_at IS NULL
    RETURNING share_id
)
SELECT count(*) = 0 AS valid FROM again \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The public identifier is a name, not a permission: it opens no share.
SELECT count(*) = 0 AS valid
FROM document AS d
JOIN document_share AS s
  ON s.token_hash = sha256(convert_to(d.public_id::text, 'UTF8')) \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Authenticated route: the identifier is fine because ownership is checked.
SELECT count(*) = 0 AS valid FROM document
WHERE public_id = (SELECT public_id FROM document WHERE document_id = 1042)
  AND owner_id = 1 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- While the legacy window is open, enumeration still works: the attacker
-- submits md5(n) and the server digests it.
SELECT count(DISTINCT s.document_id) = 1 AS valid
FROM generate_series(1, 5000) AS guess(n)
JOIN document_share AS s
  ON s.token_hash = sha256(convert_to(md5(guess.n::text), 'UTF8'))
WHERE s.revoked_at IS NULL AND s.expires_at > now() \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Migration step 5: close the window, then drop the old columns.
UPDATE document_share SET revoked_at = now(), revoked_by = created_by
WHERE origin = 'legacy' AND revoked_at IS NULL;
ALTER TABLE document DROP COLUMN share_key, DROP COLUMN is_shared;

-- The same enumeration, over every deterministic encoding, now finds nothing.
SELECT count(*) = 0 AS valid
FROM generate_series(1, 5000) AS guess(n)
CROSS JOIN LATERAL (VALUES
    (md5(guess.n::text)),
    (encode(sha256(convert_to(guess.n::text, 'UTF8')), 'hex')),
    (encode(convert_to(guess.n::text, 'UTF8'), 'base64')),
    (guess.n::text)
) AS candidate(token)
JOIN document_share AS s
  ON s.token_hash = sha256(convert_to(candidate.token, 'UTF8'))
WHERE s.revoked_at IS NULL AND s.expires_at > now() \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- PostgreSQL 18.7 has no base64url format in encode(); the application
-- produces the URL-safe text.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT encode(sha256(convert_to('x', 'UTF8')), 'base64url');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '22023'
   AND :'rejected_message' = 'unrecognized encoding: "base64url"'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

------------------------------------------------------------------------------
-- Constraints reject what a careless code path would write.
------------------------------------------------------------------------------

-- Storing the token itself instead of its digest.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO document_share (document_id, token_hash, created_by, expires_at)
VALUES (1041, convert_to('shr_lab_plaintext_not_random', 'UTF8'), 1, now() + interval '1 day');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND :'rejected_message' = 'new row for relation "document_share" violates check constraint "document_share_token_hash_length"'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The same token issued twice.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO document_share (document_id, token_hash, created_by, expires_at)
VALUES (1043, sha256(convert_to('shr_lab_offer_letter_not_random', 'UTF8')), 2, now() + interval '1 day');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505'
   AND :'rejected_message' = 'duplicate key value violates unique constraint "document_share_token_hash_key"'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A scope the share endpoint does not implement.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO document_share (document_id, token_hash, scope, created_by, expires_at)
VALUES (1041, sha256(convert_to('shr_lab_write_scope_not_random', 'UTF8')), 'write', 1, now() + interval '1 day');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND :'rejected_message' = 'new row for relation "document_share" violates check constraint "document_share_scope"'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A link that would live for a year.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO document_share (document_id, token_hash, created_by, expires_at)
VALUES (1041, sha256(convert_to('shr_lab_forever_not_random', 'UTF8')), 1, now() + interval '1 year');
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND :'rejected_message' = 'new row for relation "document_share" violates check constraint "document_share_lifetime"'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Revocation without recording who revoked.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE document_share SET revoked_at = now()
WHERE token_hash = sha256(convert_to('shr_lab_forecast_for_client_not_random', 'UTF8'));
\set rejected_state :SQLSTATE
\set rejected_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514'
   AND :'rejected_message' = 'new row for relation "document_share" violates check constraint "document_share_revocation"'
   AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
