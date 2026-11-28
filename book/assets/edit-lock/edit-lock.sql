-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f edit-lock.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
-- One session plays every user in turn; lease expiry is simulated by moving
-- a lock's acquired_at and expires_at into the past together.
\set ON_ERROR_STOP on
-- A failed check divides by zero, so ON_ERROR_STOP makes psql exit with a non-zero status.
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA edit_lock_example;
SET LOCAL search_path = edit_lock_example;

CREATE TABLE app_user (
    user_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE document (
    document_id bigint PRIMARY KEY,
    title text NOT NULL
);
CREATE TABLE document_section (
    section_id bigint PRIMARY KEY,
    document_id bigint NOT NULL REFERENCES document (document_id),
    body text NOT NULL
);

-- Release deletes the lock row, so generations come from a sequence:
-- a later lock on the same document never reuses an old token.
CREATE SEQUENCE lock_generation;
CREATE TABLE edit_lock (
    document_id bigint PRIMARY KEY REFERENCES document (document_id) ON DELETE CASCADE,
    holder_id bigint NOT NULL REFERENCES app_user (user_id),
    generation bigint NOT NULL UNIQUE DEFAULT nextval('lock_generation'),
    acquired_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    CONSTRAINT edit_lock_lease CHECK (expires_at > acquired_at)
);
CREATE INDEX edit_lock_expiry_idx ON edit_lock (expires_at);

INSERT INTO app_user VALUES (1, 'Ada'), (2, 'Bob'), (3, 'Admin');
INSERT INTO document VALUES (1, 'Supply contract');
INSERT INTO document_section VALUES (10, 1, 'Payment terms: 30 days'), (11, 1, 'Delivery: FOB');

-- Ada acquires the lock for the whole document: one statement, insert or take over an expired lock.
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (1, 1, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    WHERE edit_lock.expires_at <= clock_timestamp()
    RETURNING generation
)
SELECT count(*) = 1 AS valid, max(generation) AS ada_generation FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob runs the same statement while Ada's lease is live: zero rows, no error.
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (1, 2, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    WHERE edit_lock.expires_at <= clock_timestamp()
    RETURNING generation
)
SELECT count(*) = 0 AS valid FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Ada's second browser tab is refused too: the holder alone does not identify a lock.
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (1, 1, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    WHERE edit_lock.expires_at <= clock_timestamp()
    RETURNING generation
)
SELECT count(*) = 0 AS valid FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob's screen shows who holds the lock and until when.
SELECT u.name = 'Ada' AND l.expires_at > clock_timestamp() AS valid
FROM edit_lock AS l JOIN app_user AS u ON u.user_id = l.holder_id
WHERE l.document_id = 1 AND l.expires_at > clock_timestamp() \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A plain insert without the takeover clause is rejected by the primary key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
VALUES (1, 2, clock_timestamp(), clock_timestamp() + interval '15 minutes');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A lease must end after it starts.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE edit_lock SET expires_at = acquired_at WHERE document_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Heartbeat: Ada's live lease with her generation is extended.
SELECT expires_at AS old_expiry FROM edit_lock WHERE document_id = 1 \gset
WITH renewed AS (
    UPDATE edit_lock SET expires_at = clock_timestamp() + interval '20 minutes'
    WHERE document_id = 1 AND holder_id = 1 AND generation = :ada_generation
      AND expires_at > clock_timestamp()
    RETURNING expires_at
)
SELECT count(*) = 1 AND max(expires_at) > :'old_expiry'::timestamptz AS valid FROM renewed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Ada saves a section: lock the lock row, then write only while the lock is hers.
SELECT count(*) = 1 AS valid FROM (
    SELECT document_id FROM edit_lock WHERE document_id = 1 FOR SHARE
) AS locked \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH saved AS (
    UPDATE document_section SET body = 'Payment terms: 45 days'
    WHERE document_id = 1 AND section_id = 10
      AND EXISTS (
          SELECT FROM edit_lock
          WHERE document_id = 1 AND holder_id = 1 AND generation = :ada_generation
            AND expires_at > clock_timestamp())
    RETURNING section_id
)
SELECT count(*) = 1 AS valid FROM saved \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob cannot save without the lock, even for a different section of the same document.
WITH saved AS (
    UPDATE document_section SET body = 'Delivery: CIF'
    WHERE document_id = 1 AND section_id = 11
      AND EXISTS (
          SELECT FROM edit_lock
          WHERE document_id = 1 AND holder_id = 2 AND generation = :ada_generation
            AND expires_at > clock_timestamp())
    RETURNING section_id
)
SELECT count(*) = 0 AS valid FROM saved \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Ada's laptop sleeps: simulate the lease running out by moving it an hour into the past.
UPDATE edit_lock
SET acquired_at = acquired_at - interval '1 hour', expires_at = expires_at - interval '1 hour'
WHERE document_id = 1;

-- An expired lock is shown as free, and its holder can no longer renew it.
SELECT count(*) = 0 AS valid FROM edit_lock
WHERE document_id = 1 AND expires_at > clock_timestamp() \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH renewed AS (
    UPDATE edit_lock SET expires_at = clock_timestamp() + interval '20 minutes'
    WHERE document_id = 1 AND holder_id = 1 AND generation = :ada_generation
      AND expires_at > clock_timestamp()
    RETURNING expires_at
)
SELECT count(*) = 0 AS valid FROM renewed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob takes over the expired lock with the same acquire statement and gets a new generation.
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (1, 2, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    WHERE edit_lock.expires_at <= clock_timestamp()
    RETURNING generation
)
SELECT count(*) = 1 AND max(generation) > :ada_generation AS valid,
       max(generation) AS bob_generation FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Refused acquires and the rejected plain insert consumed sequence values: gaps are expected.
SELECT :bob_generation > :ada_generation + 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Ada's laptop wakes up and sends the save it queued: rejected, the section keeps its text.
SELECT document_id FROM edit_lock WHERE document_id = 1 FOR SHARE \g /dev/null
WITH saved AS (
    UPDATE document_section SET body = 'Payment terms: 60 days'
    WHERE document_id = 1 AND section_id = 10
      AND EXISTS (
          SELECT FROM edit_lock
          WHERE document_id = 1 AND holder_id = 1 AND generation = :ada_generation
            AND expires_at > clock_timestamp())
    RETURNING section_id
)
SELECT count(*) = 0 AS valid FROM saved \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT body = 'Payment terms: 45 days' AS valid FROM document_section WHERE section_id = 10 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Ada's late release deletes nothing: Bob's lock survives.
WITH released AS (
    DELETE FROM edit_lock WHERE document_id = 1 AND generation = :ada_generation
    RETURNING document_id
)
SELECT count(*) = 0 AS valid FROM released \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT holder_id = 2 AS valid FROM edit_lock WHERE document_id = 1 \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An administrator takes over a live lock: an upsert without the expiry condition.
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (1, 3, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    RETURNING generation
)
SELECT count(*) = 1 AND max(generation) > :bob_generation AS valid,
       max(generation) AS admin_generation FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob's heartbeat on the administrator's live lock is rejected.
WITH renewed AS (
    UPDATE edit_lock SET expires_at = clock_timestamp() + interval '20 minutes'
    WHERE document_id = 1 AND holder_id = 2 AND generation = :bob_generation
      AND expires_at > clock_timestamp()
    RETURNING expires_at
)
SELECT count(*) = 0 AS valid FROM renewed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob's generation is now stale: his save is rejected.
WITH saved AS (
    UPDATE document_section SET body = 'Delivery: CIF'
    WHERE document_id = 1 AND section_id = 11
      AND EXISTS (
          SELECT FROM edit_lock
          WHERE document_id = 1 AND holder_id = 2 AND generation = :bob_generation
            AND expires_at > clock_timestamp())
    RETURNING section_id
)
SELECT count(*) = 0 AS valid FROM saved \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The same administrator statement also works when no lock row exists.
INSERT INTO document VALUES (2, 'Price list');
INSERT INTO document_section VALUES (20, 2, 'Prices: list A');
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (2, 3, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    RETURNING generation
)
SELECT count(*) = 1 AS valid FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Release deletes the row; re-acquiring the document issues a generation never used before.
WITH released AS (
    DELETE FROM edit_lock WHERE document_id = 1 AND generation = :admin_generation
    RETURNING document_id
)
SELECT count(*) = 1 AS valid FROM released \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH acquired AS (
    INSERT INTO edit_lock (document_id, holder_id, acquired_at, expires_at)
    VALUES (1, 1, clock_timestamp(), clock_timestamp() + interval '15 minutes')
    ON CONFLICT (document_id) DO UPDATE
    SET holder_id = EXCLUDED.holder_id, generation = EXCLUDED.generation,
        acquired_at = EXCLUDED.acquired_at, expires_at = EXCLUDED.expires_at
    WHERE edit_lock.expires_at <= clock_timestamp()
    RETURNING generation
)
SELECT count(*) = 1 AND max(generation) > :admin_generation AS valid,
       max(generation) AS ada_new_generation FROM acquired \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Ada's first-session token stays dead although Ada holds the document again.
WITH saved AS (
    UPDATE document_section SET body = 'Payment terms: 60 days'
    WHERE document_id = 1 AND section_id = 10
      AND EXISTS (
          SELECT FROM edit_lock
          WHERE document_id = 1 AND holder_id = 1 AND generation = :ada_generation
            AND expires_at > clock_timestamp())
    RETURNING section_id
)
SELECT count(*) = 0 AS valid FROM saved \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A cleanup job may delete expired rows; acquisition does not depend on it.
UPDATE edit_lock
SET acquired_at = acquired_at - interval '1 hour', expires_at = expires_at - interval '1 hour'
WHERE document_id = 2;
WITH swept AS (
    DELETE FROM edit_lock WHERE expires_at <= clock_timestamp() RETURNING document_id
)
SELECT count(*) = 1 AND min(document_id) = 2 AS valid FROM swept \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- With no lock row at all, a guarded save changes nothing.
SELECT count(*) = 0 AS valid FROM (
    SELECT document_id FROM edit_lock WHERE document_id = 2 FOR SHARE
) AS locked \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH saved AS (
    UPDATE document_section SET body = 'Prices: list B'
    WHERE document_id = 2 AND section_id = 20
      AND EXISTS (
          SELECT FROM edit_lock
          WHERE document_id = 2 AND holder_id = 3 AND generation = :admin_generation
            AND expires_at > clock_timestamp())
    RETURNING section_id
)
SELECT count(*) = 0 AS valid FROM saved \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Deleting a document removes its lock with it.
DELETE FROM document_section WHERE document_id = 1;
DELETE FROM document WHERE document_id = 1;
SELECT count(*) = 0 AS valid FROM edit_lock \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
