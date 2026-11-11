-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f idempotency-record.sql in a disposable database.
-- Expected errors are isolated and their SQLSTATEs checked; all other errors stop execution.
\set ON_ERROR_STOP on
CREATE SCHEMA idempotency_record_lab;
SET search_path = idempotency_record_lab, public;

CREATE TABLE account (
    account_id bigint PRIMARY KEY,
    balance bigint NOT NULL CHECK (balance >= 0)
);
CREATE TABLE request_result (
    account_id bigint NOT NULL REFERENCES account (account_id),
    operation text COLLATE "C" NOT NULL,
    request_key text COLLATE "C" NOT NULL,
    request jsonb NOT NULL,
    response jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT request_result_pkey PRIMARY KEY (account_id, operation, request_key)
);
CREATE FUNCTION debit_once(p_account bigint, p_key text, p_amount bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    supplied jsonb := jsonb_build_object('amount', p_amount);
    saved_request jsonb;
    reply jsonb;
    remaining bigint;
BEGIN
    IF p_key IS NULL OR p_key = '' OR p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'key and positive amount required' USING ERRCODE = '22023';
    END IF;
    INSERT INTO request_result (account_id, operation, request_key, request, response)
    VALUES (p_account, 'debit:v1', p_key, supplied, '{}'::jsonb)
    ON CONFLICT (account_id, operation, request_key) DO NOTHING;
    IF NOT FOUND THEN
        SELECT request, response INTO STRICT saved_request, reply
        FROM request_result
        WHERE account_id = p_account AND operation = 'debit:v1' AND request_key = p_key;
        IF saved_request IS DISTINCT FROM supplied THEN
            RAISE EXCEPTION 'idempotency key reused with different request'
                USING ERRCODE = '22023';
        END IF;
        RETURN reply;
    END IF;
    UPDATE account SET balance = balance - p_amount
    WHERE account_id = p_account AND balance >= p_amount
    RETURNING balance INTO remaining;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'insufficient balance' USING ERRCODE = 'P0001';
    END IF;
    reply := jsonb_build_object('balance', remaining);
    UPDATE request_result SET response = reply
    WHERE account_id = p_account AND operation = 'debit:v1' AND request_key = p_key;
    RETURN reply;
END;
$$;
INSERT INTO account VALUES (1, 1000);
SELECT debit_once(1, 'checkout-42', 100);
SELECT debit_once(1, 'checkout-42', 100);
SELECT balance FROM account WHERE account_id = 1;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
-- Expected SQLSTATE 22023.
SELECT debit_once(1, 'checkout-42', 101);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '22023' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
-- Expected SQLSTATE 23505.
INSERT INTO request_result (account_id, operation, request_key, request, response)
VALUES (1, 'debit:v1', 'checkout-42', '{"amount":100}', '{"balance":900}');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

CREATE TABLE processed_message (
    subscriber text NOT NULL,
    message_id uuid NOT NULL,
    account_id bigint NOT NULL REFERENCES account (account_id),
    PRIMARY KEY (subscriber, message_id)
);
WITH accepted AS (
    INSERT INTO processed_message VALUES
        ('balance-projection', '00000000-0000-4000-8000-000000000001', 1)
    ON CONFLICT DO NOTHING
    RETURNING account_id
)
UPDATE account SET balance = balance + 50
WHERE account_id IN (SELECT account_id FROM accepted)
RETURNING balance;


-- Redelivery of the same event changes nothing.
WITH accepted AS (
    INSERT INTO processed_message VALUES
        ('balance-projection', '00000000-0000-4000-8000-000000000001', 1)
    ON CONFLICT DO NOTHING RETURNING account_id
)
UPDATE account SET balance = balance + 50
WHERE account_id IN (SELECT account_id FROM accepted);
DO $$ BEGIN
    IF (SELECT balance FROM account WHERE account_id = 1) <> 950 THEN
        RAISE EXCEPTION 'consumer redelivery repeated effect';
    END IF;
END $$;
BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
SELECT debit_once(1, 'too-large', 1001);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM request_result WHERE request_key = 'too-large') THEN
        RAISE EXCEPTION 'failed effect retained a provisional key';
    END IF;
END $$;
SELECT debit_once(1, 'next-operation', 100);
SELECT debit_once(1, 'checkout-42', 100);
-- Original response is still 900; current balance is now 850.
DO $$ BEGIN
    IF debit_once(1, 'checkout-42', 100) <> '{"balance":900}'::jsonb
       OR (SELECT balance FROM account WHERE account_id = 1) <> 850 THEN
        RAISE EXCEPTION 'replay did not retain original result';
    END IF;
END $$;

RESET search_path;
DROP SCHEMA idempotency_record_lab CASCADE;
