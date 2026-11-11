-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f queue-table.sql in a disposable database.
-- Expected errors are isolated and their SQLSTATEs checked; all other errors stop execution.
\set ON_ERROR_STOP on
CREATE SCHEMA queue_table_lab;
SET search_path = queue_table_lab, public;

CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    state text NOT NULL
);
CREATE TABLE job (
    job_id bigint PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES customer_order (order_id),
    queue text NOT NULL,
    payload jsonb NOT NULL,
    state text NOT NULL DEFAULT 'ready'
        CHECK (state IN ('ready', 'running', 'succeeded', 'dead')),
    priority integer NOT NULL DEFAULT 0,
    run_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts > 0),
    worker_id text,
    lease_until timestamptz,
    finished_at timestamptz,
    CONSTRAINT job_claim_shape CHECK (
        (state = 'running' AND worker_id IS NOT NULL AND lease_until IS NOT NULL)
        OR (state <> 'running' AND worker_id IS NULL AND lease_until IS NULL)
    ),
    CONSTRAINT job_finish_shape CHECK (
        (state IN ('succeeded', 'dead')) = (finished_at IS NOT NULL)
    )
);
CREATE INDEX job_ready_idx ON job (queue, priority DESC, run_at, job_id)
WHERE state = 'ready';
CREATE INDEX job_lease_idx ON job (lease_until) WHERE state = 'running';
BEGIN;
INSERT INTO customer_order VALUES (1, 'paid');
INSERT INTO job (job_id, order_id, queue, payload)
VALUES (1, 1, 'invoices', '{"schema_version":1}');
COMMIT;

BEGIN;
WITH candidate AS (
    SELECT job_id FROM job
    WHERE queue = 'invoices' AND state = 'ready'
      AND run_at <= statement_timestamp() AND attempts < max_attempts
    ORDER BY priority DESC, run_at, job_id
    LIMIT 1 FOR UPDATE SKIP LOCKED
)
UPDATE job AS j
SET state = 'running', attempts = j.attempts + 1,
    worker_id = 'worker-a', lease_until = clock_timestamp() + interval '1 minute'
FROM candidate AS c WHERE j.job_id = c.job_id
RETURNING j.job_id, j.attempts, j.payload;
COMMIT;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
-- Expected SQLSTATE 23514.
UPDATE job SET lease_until = NULL WHERE job_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

BEGIN;
SELECT job_id FROM job WHERE job_id = 1 FOR UPDATE;
UPDATE job SET lease_until = clock_timestamp() + interval '1 minute'
WHERE job_id = 1 AND state = 'running' AND attempts = 1 AND worker_id = 'worker-a'
  AND lease_until > clock_timestamp()
RETURNING job_id;
COMMIT;

BEGIN;
SELECT job_id FROM job WHERE job_id = 1 FOR UPDATE;
UPDATE job SET state = 'succeeded', worker_id = NULL, lease_until = NULL,
               finished_at = clock_timestamp()
WHERE job_id = 1 AND state = 'running' AND attempts = 1 AND worker_id = 'worker-a'
  AND lease_until > clock_timestamp()
RETURNING job_id, state;
COMMIT;

WITH overdue AS (
    SELECT job_id FROM job
    WHERE state = 'running' AND lease_until <= statement_timestamp()
    ORDER BY lease_until, job_id
    LIMIT 100 FOR UPDATE SKIP LOCKED
)
UPDATE job AS j
SET state = CASE WHEN j.attempts >= j.max_attempts THEN 'dead' ELSE 'ready' END,
    run_at = clock_timestamp() + interval '30 seconds',
    worker_id = NULL, lease_until = NULL,
    finished_at = CASE WHEN j.attempts >= j.max_attempts THEN clock_timestamp() END
FROM overdue AS o WHERE j.job_id = o.job_id
RETURNING j.job_id, j.state;


-- A second job exercises abandoned leases and replacement ownership.
INSERT INTO job (job_id, order_id, queue, payload, max_attempts)
VALUES (2, 1, 'invoices', '{}', 2);
WITH candidate AS (
    SELECT job_id FROM job WHERE job_id = 2 AND state = 'ready'
    FOR UPDATE SKIP LOCKED
)
UPDATE job AS j SET state = 'running', attempts = j.attempts + 1,
    worker_id = 'old-worker', lease_until = clock_timestamp() - interval '1 second'
FROM candidate AS c WHERE j.job_id = c.job_id;
-- Reap the expired first attempt, scheduling retry.
WITH overdue AS (
    SELECT job_id FROM job WHERE state = 'running' AND lease_until <= statement_timestamp()
    LIMIT 100 FOR UPDATE SKIP LOCKED
)
UPDATE job AS j
SET state = CASE WHEN j.attempts >= j.max_attempts THEN 'dead' ELSE 'ready' END,
    run_at = clock_timestamp() + interval '30 seconds', worker_id = NULL, lease_until = NULL,
    finished_at = CASE WHEN j.attempts >= j.max_attempts THEN clock_timestamp() END
FROM overdue AS o WHERE j.job_id = o.job_id;
-- Advance the test schedule without waiting 30 seconds.
UPDATE job SET run_at = clock_timestamp() - interval '1 second' WHERE job_id = 2;
WITH candidate AS (
    SELECT job_id FROM job WHERE state = 'ready' AND run_at <= statement_timestamp()
        AND attempts < max_attempts ORDER BY priority DESC, run_at, job_id
    LIMIT 1 FOR UPDATE SKIP LOCKED
)
UPDATE job AS j SET state = 'running', attempts = j.attempts + 1,
    worker_id = 'replacement', lease_until = clock_timestamp() + interval '1 minute'
FROM candidate AS c WHERE j.job_id = c.job_id;
-- This stale acknowledgement must affect zero rows.
WITH stale AS (
    UPDATE job SET state = 'succeeded', worker_id = NULL, lease_until = NULL,
        finished_at = clock_timestamp()
    WHERE job_id = 2 AND state = 'running' AND attempts = 1 AND worker_id = 'old-worker'
        AND lease_until > clock_timestamp() RETURNING job_id
)
SELECT count(*) AS stale_acknowledgements FROM stale;
DO $$ BEGIN
    IF (SELECT attempts <> 2 OR state <> 'running' OR worker_id <> 'replacement'
        FROM job WHERE job_id = 2) THEN
        RAISE EXCEPTION 'stale worker changed replacement claim';
    END IF;
END $$;
-- Renew the live replacement generation.
BEGIN;
SELECT job_id FROM job WHERE job_id = 2 FOR UPDATE;
UPDATE job SET lease_until = clock_timestamp() + interval '2 minutes'
WHERE job_id = 2 AND state = 'running' AND attempts = 2 AND worker_id = 'replacement'
    AND lease_until > clock_timestamp();
COMMIT;
-- A voluntary failure at the attempt limit is terminal.
BEGIN;
SELECT job_id FROM job WHERE job_id = 2 FOR UPDATE;
UPDATE job SET state = CASE WHEN attempts >= max_attempts THEN 'dead' ELSE 'ready' END,
    run_at = clock_timestamp() + interval '30 seconds', worker_id = NULL, lease_until = NULL,
    finished_at = CASE WHEN attempts >= max_attempts THEN clock_timestamp() END
WHERE job_id = 2 AND state = 'running' AND attempts = 2 AND worker_id = 'replacement'
    AND lease_until > clock_timestamp();
COMMIT;
SELECT job_id, state, attempts FROM job ORDER BY job_id;
DO $$ BEGIN
    IF (SELECT state FROM job WHERE job_id = 1) <> 'succeeded'
       OR (SELECT state FROM job WHERE job_id = 2) <> 'dead' THEN
        RAISE EXCEPTION 'terminal job states incorrect';
    END IF;
END $$;

RESET search_path;
DROP SCHEMA queue_table_lab CASCADE;
