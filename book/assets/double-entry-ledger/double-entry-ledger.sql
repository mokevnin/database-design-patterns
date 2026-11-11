-- Checked on PostgreSQL 18.6 (Homebrew).
-- Positive amounts are debits; negative amounts are credits. One currency per journal.
-- Drafts exist only inside a transaction; every committed journal must be posted.
\set ON_ERROR_STOP on
CREATE SCHEMA ledger_example;
SET search_path = ledger_example, public;

CREATE TABLE account (
    account_id bigint PRIMARY KEY,
    name text NOT NULL,
    currency text NOT NULL,
    normal_side text NOT NULL CHECK (normal_side IN ('debit', 'credit')),
    UNIQUE (account_id, currency)
);
CREATE TABLE journal (
    journal_id bigint PRIMARY KEY,
    request_key text NOT NULL UNIQUE,
    currency text NOT NULL,
    effective_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'posted')),
    reversal_of bigint UNIQUE,
    UNIQUE (journal_id, currency),
    FOREIGN KEY (reversal_of, currency) REFERENCES journal (journal_id, currency),
    CHECK (reversal_of <> journal_id)
);
CREATE TABLE entry (
    journal_id bigint,
    entry_no integer CHECK (entry_no > 0),
    account_id bigint NOT NULL,
    currency text NOT NULL,
    amount numeric NOT NULL,
    PRIMARY KEY (journal_id, entry_no),
    FOREIGN KEY (journal_id, currency) REFERENCES journal (journal_id, currency),
    FOREIGN KEY (account_id, currency) REFERENCES account (account_id, currency),
    CONSTRAINT entry_amount CHECK (amount <> 0 AND amount > -1000000000000
        AND amount < 1000000000000 AND scale(amount) <= 2)
);
CREATE INDEX entry_account_idx ON entry (account_id, journal_id);
CREATE FUNCTION guard_entry() RETURNS trigger LANGUAGE plpgsql SET search_path = ledger_example, pg_temp AS $$
DECLARE
    journal_state text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'ledger entries are immutable' USING ERRCODE = '23514';
    END IF;
    SELECT state INTO journal_state FROM journal
    WHERE journal_id = NEW.journal_id FOR UPDATE;
    IF journal_state IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'entries require a draft journal' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER entry_guard BEFORE INSERT OR UPDATE OR DELETE ON entry
    FOR EACH ROW EXECUTE FUNCTION guard_entry();
CREATE FUNCTION guard_journal() RETURNS trigger LANGUAGE plpgsql SET search_path = ledger_example, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.state <> 'draft' THEN
            RAISE EXCEPTION 'create journals in draft' USING ERRCODE = '23514';
        END IF;
        IF NEW.reversal_of IS NOT NULL AND NOT EXISTS (
            SELECT FROM journal WHERE journal_id = NEW.reversal_of AND state = 'posted'
        ) THEN
            RAISE EXCEPTION 'reversal requires a posted original' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_OP = 'DELETE' OR OLD.state = 'posted' THEN
        RAISE EXCEPTION 'posted journal is immutable' USING ERRCODE = '23514';
    END IF;
    IF NEW.state <> 'posted' OR
        (NEW.journal_id, NEW.request_key, NEW.currency, NEW.effective_at, NEW.recorded_at, NEW.reversal_of)
        IS DISTINCT FROM
        (OLD.journal_id, OLD.request_key, OLD.currency, OLD.effective_at, OLD.recorded_at, OLD.reversal_of) THEN
        RAISE EXCEPTION 'only posting may change a draft journal' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER journal_guard BEFORE INSERT OR UPDATE OR DELETE ON journal
    FOR EACH ROW EXECUTE FUNCTION guard_journal();
CREATE FUNCTION guard_account() RETURNS trigger LANGUAGE plpgsql SET search_path = ledger_example, pg_temp AS $$
BEGIN
    RAISE EXCEPTION 'ledger account definition is immutable' USING ERRCODE = '23514';
END $$;
CREATE TRIGGER account_guard BEFORE UPDATE OR DELETE ON account
    FOR EACH ROW EXECUTE FUNCTION guard_account();

CREATE FUNCTION check_journal() RETURNS trigger LANGUAGE plpgsql SET search_path = ledger_example, pg_temp AS $$
DECLARE
    target_id bigint;
    original_id bigint;
BEGIN
    target_id := NEW.journal_id;
    SELECT reversal_of INTO original_id FROM journal WHERE journal_id = target_id;
    IF NOT EXISTS (SELECT FROM journal WHERE journal_id = target_id AND state = 'posted')
       OR (SELECT count(*) FROM entry WHERE journal_id = target_id) < 2
       OR (SELECT coalesce(sum(amount), 0) FROM entry WHERE journal_id = target_id) <> 0 THEN
        RAISE EXCEPTION 'journal must be posted with at least two balanced entries'
            USING ERRCODE = '23514';
    END IF;
    IF original_id IS NOT NULL AND EXISTS (
        SELECT FROM
            (SELECT account_id, sum(amount) AS total FROM entry
             WHERE journal_id = target_id GROUP BY account_id) AS n
        FULL JOIN
            (SELECT account_id, sum(amount) AS total FROM entry
             WHERE journal_id = original_id GROUP BY account_id) AS o USING (account_id)
        WHERE coalesce(n.total, 0) <> -coalesce(o.total, 0)
    ) THEN
        RAISE EXCEPTION 'reversal must negate original account totals' USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER journal_balanced AFTER INSERT OR UPDATE ON journal
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_journal();
CREATE CONSTRAINT TRIGGER entry_balanced AFTER INSERT ON entry
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_journal();

INSERT INTO account VALUES
    (1, 'Cash', 'EUR', 'debit'), (2, 'Customer liability', 'EUR', 'credit'),
    (3, 'Dollar cash', 'USD', 'debit');
BEGIN;
INSERT INTO journal (journal_id, request_key, currency, effective_at)
VALUES (100, 'deposit:104', 'EUR', '2026-11-01 10:00Z');
INSERT INTO entry VALUES (100, 1, 1, 'EUR', 100), (100, 2, 2, 'EUR', -100);
UPDATE journal SET state = 'posted' WHERE journal_id = 100;
COMMIT;
SELECT a.account_id, a.normal_side,
       CASE WHEN a.normal_side = 'debit' THEN coalesce(sum(e.amount), 0)
            ELSE -coalesce(sum(e.amount), 0) END AS normal_balance
FROM account AS a LEFT JOIN entry AS e USING (account_id)
GROUP BY a.account_id ORDER BY a.account_id;

-- Force deferred validation inside each subtransaction so the script checks failures.
DO $$
BEGIN
    BEGIN
        INSERT INTO journal (journal_id, request_key, currency, effective_at)
        VALUES (101, 'bad:101', 'EUR', '2026-11-01 10:00Z');
        INSERT INTO entry VALUES (101, 1, 1, 'EUR', 100), (101, 2, 2, 'EUR', -90);
        UPDATE journal SET state = 'posted' WHERE journal_id = 101;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'expected imbalance';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'journal must be posted with at least two balanced entries' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        UPDATE entry SET amount = 90 WHERE journal_id = 100 AND entry_no = 1;
        RAISE EXCEPTION 'expected immutable posting';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'ledger entries are immutable' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO journal (journal_id, request_key, currency, effective_at)
        VALUES (102, 'deposit:104', 'EUR', '2026-11-01 10:00Z');
        RAISE EXCEPTION 'expected duplicate request';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO journal (journal_id, request_key, currency, effective_at)
        VALUES (103, 'bad:currency', 'EUR', '2026-11-01 10:00Z');
        INSERT INTO entry VALUES (103, 1, 3, 'EUR', 100);
        RAISE EXCEPTION 'expected account currency mismatch';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT NOT EXISTS (SELECT FROM journal WHERE journal_id = 101);
END $$;

BEGIN;
INSERT INTO journal (journal_id, request_key, currency, effective_at, reversal_of)
VALUES (104, 'reverse:104', 'EUR', '2026-11-02 10:00Z', 100);
INSERT INTO entry
SELECT 104, entry_no, account_id, currency, -amount FROM entry WHERE journal_id = 100;
UPDATE journal SET state = 'posted' WHERE journal_id = 104;
COMMIT;
SELECT account_id, sum(amount) AS signed_balance FROM entry GROUP BY account_id ORDER BY account_id;
DO $$
BEGIN
    ASSERT NOT EXISTS (SELECT FROM entry GROUP BY account_id HAVING sum(amount) <> 0);
    ASSERT (SELECT count(*) FROM journal) = 2;
END $$;
