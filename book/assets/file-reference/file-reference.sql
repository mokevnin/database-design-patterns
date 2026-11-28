-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f file-reference.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA file_example;

-- One row per stored object: where it lives, what it is, and how far its upload got.
CREATE TABLE file_example.stored_file (
    file_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bucket text NOT NULL,
    storage_key text NOT NULL,
    original_filename text NOT NULL,
    content_type text NOT NULL,
    byte_size bigint CHECK (byte_size >= 0),
    sha256 bytea CHECK (octet_length(sha256) = 32),
    state text NOT NULL DEFAULT 'pending'
        CHECK (state IN ('pending', 'stored', 'deleted')),
    created_at timestamptz NOT NULL DEFAULT now(),
    stored_at timestamptz,
    deleted_at timestamptz,
    CONSTRAINT stored_file_location_key UNIQUE (bucket, storage_key),
    CONSTRAINT stored_file_state_key UNIQUE (file_id, state),
    CONSTRAINT stored_file_content_known CHECK (
        state <> 'stored'
        OR (byte_size IS NOT NULL AND sha256 IS NOT NULL AND stored_at IS NOT NULL)),
    CONSTRAINT stored_file_deleted_at CHECK ((state = 'deleted') = (deleted_at IS NOT NULL))
);
-- Deduplication option: one live row per verified content hash.
CREATE UNIQUE INDEX stored_file_sha256_live ON file_example.stored_file (sha256)
WHERE state = 'stored';
CREATE INDEX stored_file_sweep_idx ON file_example.stored_file (state, created_at);

CREATE TABLE file_example.product (
    product_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE file_example.invoice (
    invoice_id bigint PRIMARY KEY,
    number text NOT NULL UNIQUE
);

-- Typed attachments: one table per role, each with real foreign keys at both ends.
-- file_state is always 'stored', so the pair can only reference a stored file.
CREATE TABLE file_example.product_image (
    product_id bigint NOT NULL
        REFERENCES file_example.product (product_id) ON DELETE CASCADE,
    file_id bigint NOT NULL,
    file_state text NOT NULL DEFAULT 'stored' CHECK (file_state = 'stored'),
    PRIMARY KEY (product_id, file_id),
    CONSTRAINT product_image_file_fkey FOREIGN KEY (file_id, file_state)
        REFERENCES file_example.stored_file (file_id, state)
);
CREATE INDEX product_image_file_idx ON file_example.product_image (file_id);
CREATE TABLE file_example.invoice_document (
    invoice_id bigint PRIMARY KEY
        REFERENCES file_example.invoice (invoice_id) ON DELETE CASCADE,
    file_id bigint NOT NULL,
    file_state text NOT NULL DEFAULT 'stored' CHECK (file_state = 'stored'),
    CONSTRAINT invoice_document_file_fkey FOREIGN KEY (file_id, file_state)
        REFERENCES file_example.stored_file (file_id, state)
);
CREATE INDEX invoice_document_file_idx ON file_example.invoice_document (file_id);

INSERT INTO file_example.product VALUES (1, 'Desk lamp'), (2, 'Floor lamp');
INSERT INTO file_example.invoice VALUES (1, 'INV-2026-0001');

-- Step 1: commit a pending row before the client uploads anything.
INSERT INTO file_example.stored_file
    (bucket, storage_key, original_filename, content_type)
VALUES ('media', 'uploads/0b8f2c1e-lamp', 'lamp.jpg', 'image/jpeg');
SELECT (SELECT state = 'pending' FROM file_example.stored_file WHERE file_id = 1)
    AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A pending file cannot be attached: the reference names the stored state.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO file_example.product_image (product_id, file_id) VALUES (1, 1);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A stored file without a verified size and checksum is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE file_example.stored_file SET state = 'stored', stored_at = now()
WHERE file_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Step 2: after the upload, finalize only if the row is still pending, then attach.
WITH finalized AS (
    UPDATE file_example.stored_file
    SET state = 'stored', byte_size = 18, stored_at = now(),
        sha256 = sha256('lamp photo content'::bytea)
    WHERE file_id = 1 AND state = 'pending'
    RETURNING file_id
)
SELECT count(*) = 1 AS valid FROM finalized \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
INSERT INTO file_example.product_image (product_id, file_id) VALUES (1, 1);

-- A second finalize of the same row finds nothing to change.
WITH finalized AS (
    UPDATE file_example.stored_file SET stored_at = now()
    WHERE file_id = 1 AND state = 'pending'
    RETURNING file_id
)
SELECT count(*) = 0 AS valid FROM finalized \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Deduplication: a second upload of the same bytes cannot become a second live row.
INSERT INTO file_example.stored_file
    (bucket, storage_key, original_filename, content_type)
VALUES ('media', 'uploads/7d41a9b3-lamp-copy', 'lamp-copy.jpg', 'image/jpeg');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE file_example.stored_file
SET state = 'stored', byte_size = 18, stored_at = now(),
    sha256 = sha256('lamp photo content'::bytea)
WHERE file_id = 2 AND state = 'pending';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- The application abandons its copy and attaches the existing row instead.
UPDATE file_example.stored_file SET state = 'deleted', deleted_at = now()
WHERE file_id = 2 AND state = 'pending';
INSERT INTO file_example.product_image (product_id, file_id)
SELECT 2, file_id FROM file_example.stored_file
WHERE sha256 = sha256('lamp photo content'::bytea) AND state = 'stored';
SELECT (SELECT count(*) FROM file_example.product_image WHERE file_id = 1) = 2
    AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Detaching from product 1 leaves product 2's attachment: the file cannot be marked deleted.
DELETE FROM file_example.product_image WHERE product_id = 1 AND file_id = 1;
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE file_example.stored_file SET state = 'deleted', deleted_at = now()
WHERE file_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Deleting the product cascades to its attachment; the file is now unattached.
DELETE FROM file_example.product WHERE product_id = 2;

-- An invoice PDF uploaded and attached in the past, and two abandoned uploads.
INSERT INTO file_example.stored_file
    (bucket, storage_key, original_filename, content_type, byte_size, sha256,
     state, created_at, stored_at)
VALUES ('media', 'uploads/c3e0f6d2-inv', 'INV-2026-0001.pdf', 'application/pdf', 15,
        sha256('invoice content'::bytea), 'stored',
        now() - interval '3 days', now() - interval '3 days');
INSERT INTO file_example.invoice_document (invoice_id, file_id) VALUES (1, 3);
INSERT INTO file_example.stored_file
    (bucket, storage_key, original_filename, content_type, created_at)
VALUES ('media', 'uploads/5a9e7b10-stale', 'scan.pdf', 'application/pdf',
        now() - interval '2 days'),
       ('media', 'uploads/e81d4c62-fresh', 'scan2.pdf', 'application/pdf', now());
-- Pretend file 1 was stored two days ago, so it is past the grace period too.
UPDATE file_example.stored_file SET created_at = now() - interval '2 days',
    stored_at = now() - interval '2 days'
WHERE file_id = 1;

-- The sweeper: stale pending uploads and unattached stored files become deleted.
WITH swept AS (
    UPDATE file_example.stored_file AS f
    SET state = 'deleted', deleted_at = now()
    WHERE (f.state = 'pending' AND f.created_at < now() - interval '1 day')
       OR (f.state = 'stored' AND f.stored_at < now() - interval '1 day'
           AND NOT EXISTS (SELECT 1 FROM file_example.product_image AS i
                           WHERE i.file_id = f.file_id)
           AND NOT EXISTS (SELECT 1 FROM file_example.invoice_document AS d
                           WHERE d.file_id = f.file_id))
    RETURNING f.file_id
)
SELECT array_agg(file_id ORDER BY file_id) = ARRAY[1, 4]::bigint[] AS valid
FROM swept \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT (SELECT array_agg(state ORDER BY file_id) FROM file_example.stored_file)
    = ARRAY['deleted', 'deleted', 'stored', 'deleted', 'pending'] AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A late finalize of a swept upload changes nothing; the client must start over.
WITH finalized AS (
    UPDATE file_example.stored_file
    SET state = 'stored', byte_size = 9, stored_at = now(),
        sha256 = sha256('late scan'::bytea)
    WHERE file_id = 4 AND state = 'pending'
    RETURNING file_id
)
SELECT count(*) = 0 AS valid FROM finalized \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A deleted file cannot be attached again.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO file_example.product_image (product_id, file_id) VALUES (1, 1);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A tombstone still claims its storage key: no new row can take it before the purge.
SELECT (SELECT state = 'deleted' FROM file_example.stored_file
        WHERE storage_key = 'uploads/7d41a9b3-lamp-copy') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO file_example.stored_file
    (bucket, storage_key, original_filename, content_type)
VALUES ('media', 'uploads/7d41a9b3-lamp-copy', 'again.jpg', 'image/jpeg');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The deletion worker claims tombstones, deletes each object, then the row.
-- Deleting an object that is already gone counts as success, so a retry is harmless.
SELECT string_agg(file_id::text, ',' ORDER BY file_id) AS claimed
FROM (SELECT file_id FROM file_example.stored_file
      WHERE state = 'deleted'
      ORDER BY deleted_at, file_id
      LIMIT 10
      FOR UPDATE SKIP LOCKED) AS c \gset
SELECT :'claimed' = '1,2,4' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
DELETE FROM file_example.stored_file
WHERE file_id = ANY (string_to_array(:'claimed', ',')::bigint[]) AND state = 'deleted';
SELECT (SELECT count(*) FROM file_example.stored_file) = 2 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Option: bytes inside PostgreSQL. A 1 MiB bytea value lives in the TOAST table.
CREATE TABLE file_example.document_blob (
    document_id bigint PRIMARY KEY,
    body bytea NOT NULL
);
INSERT INTO file_example.document_blob
SELECT 1, decode(string_agg(md5(i::text), '' ORDER BY i), 'hex')
FROM generate_series(1, 65536) AS i;
SELECT (SELECT octet_length(body) FROM file_example.document_blob) = 1048576
   AND pg_relation_size('file_example.document_blob') = 8192
   AND pg_relation_size(
         (SELECT reltoastrelid FROM pg_class
          WHERE oid = 'file_example.document_blob'::regclass)) > 1048576
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Option: large objects. Creating one is transactional...
SAVEPOINT large_object;
SELECT lo_from_bytea(0, '\xdeadbeef'::bytea) AS rolled_back_oid \gset
ROLLBACK TO SAVEPOINT large_object;
SELECT NOT EXISTS (SELECT 1 FROM pg_largeobject_metadata
                   WHERE oid = :rolled_back_oid) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- ...but deleting the row that references it does not delete the object.
CREATE TABLE file_example.scan (
    scan_id bigint PRIMARY KEY,
    content oid NOT NULL
);
INSERT INTO file_example.scan VALUES (1, lo_from_bytea(0, '\xcafe'::bytea));
SELECT content AS scan_oid FROM file_example.scan WHERE scan_id = 1 \gset
DELETE FROM file_example.scan WHERE scan_id = 1;
SELECT EXISTS (SELECT 1 FROM pg_largeobject_metadata WHERE oid = :scan_oid)
    AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT lo_unlink(:scan_oid) = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT NOT EXISTS (SELECT 1 FROM pg_largeobject_metadata WHERE oid = :scan_oid)
    AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
