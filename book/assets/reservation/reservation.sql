-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f reservation.sql in a disposable database.
-- Expected errors are isolated and their SQLSTATEs checked; all other errors stop execution.
\set ON_ERROR_STOP on
CREATE SCHEMA reservation_lab;
SET search_path = reservation_lab, public;

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
CREATE TABLE room (
    room_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE slot_hold (
    hold_id bigint PRIMARY KEY,
    room_id bigint NOT NULL REFERENCES room (room_id),
    during tstzrange NOT NULL,
    state text NOT NULL CHECK (state IN ('held', 'confirmed', 'cancelled', 'expired')),
    expires_at timestamptz NOT NULL,
    CONSTRAINT slot_hold_period CHECK (
        NOT isempty(during) AND NOT lower_inf(during) AND NOT upper_inf(during)
        AND lower_inc(during) AND NOT upper_inc(during)
    ),
    CONSTRAINT slot_hold_no_overlap EXCLUDE USING gist (
        room_id WITH =, during WITH &&
    ) WHERE (state IN ('held', 'confirmed'))
);
CREATE INDEX slot_hold_expiry_idx ON slot_hold (room_id, expires_at)
WHERE state = 'held';
INSERT INTO room VALUES (1, 'Blue room');
BEGIN;
SELECT room_id FROM room WHERE room_id = 1 FOR UPDATE;
UPDATE slot_hold SET state = 'expired'
WHERE room_id = 1 AND state = 'held' AND expires_at <= clock_timestamp();
INSERT INTO slot_hold VALUES
    (1, 1, tstzrange('2027-01-01 10:00+00', '2027-01-01 11:00+00', '[)'),
     'held', clock_timestamp() + interval '10 minutes');
COMMIT;

BEGIN;
SELECT room_id FROM room WHERE room_id = 1 FOR UPDATE;
UPDATE slot_hold SET state = 'confirmed'
WHERE room_id = 1 AND hold_id = 1 AND state = 'held'
  AND expires_at > clock_timestamp()
RETURNING hold_id, state;
COMMIT;

BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
-- Expected SQLSTATE 23P01.
INSERT INTO slot_hold VALUES
    (2, 1, tstzrange('2027-01-01 10:30+00', '2027-01-01 11:30+00', '[)'),
     'held', clock_timestamp() + interval '10 minutes');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23P01' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
COMMIT;

CREATE TABLE inventory (
    item_id bigint PRIMARY KEY,
    available integer NOT NULL CHECK (available >= 0)
);
CREATE TABLE stock_hold (
    hold_id bigint PRIMARY KEY,
    item_id bigint NOT NULL REFERENCES inventory (item_id),
    quantity integer NOT NULL CHECK (quantity > 0),
    state text NOT NULL CHECK (state IN ('held', 'confirmed', 'cancelled', 'expired')),
    expires_at timestamptz NOT NULL
);
INSERT INTO inventory VALUES (1, 3);
BEGIN;
WITH taken AS (
    UPDATE inventory SET available = available - 2
    WHERE item_id = 1 AND available >= 2
    RETURNING item_id
)
INSERT INTO stock_hold
SELECT 10, item_id, 2, 'held', clock_timestamp() + interval '10 minutes'
FROM taken
RETURNING hold_id;
COMMIT;

BEGIN;
SELECT item_id FROM inventory WHERE item_id = 1 FOR UPDATE;
WITH released AS (
    UPDATE stock_hold SET state = 'cancelled'
    WHERE item_id = 1 AND hold_id = 10 AND state = 'held'
    RETURNING item_id, quantity
)
UPDATE inventory AS i SET available = i.available + r.quantity
FROM released AS r WHERE i.item_id = r.item_id
RETURNING i.available;
COMMIT;


-- Release the confirmed slot, then reclaim a persisted abandoned hold.
BEGIN;
SELECT room_id FROM room WHERE room_id = 1 FOR UPDATE;
UPDATE slot_hold SET state = 'cancelled'
WHERE room_id = 1 AND hold_id = 1 AND state IN ('held', 'confirmed');
INSERT INTO slot_hold VALUES
    (2, 1, tstzrange('2027-01-01 10:00+00', '2027-01-01 11:00+00', '[)'),
     'held', clock_timestamp() - interval '1 second');
UPDATE slot_hold SET state = 'expired'
WHERE room_id = 1 AND state = 'held' AND expires_at <= clock_timestamp();
UPDATE slot_hold SET state = 'confirmed'
WHERE room_id = 1 AND hold_id = 2 AND state = 'held'
  AND expires_at > clock_timestamp();
COMMIT;
SELECT hold_id, state FROM slot_hold ORDER BY hold_id;
-- Expected: cancelled, expired. The late confirmation updated zero rows.

-- Repeated stock cancellation must not release twice.
BEGIN;
SELECT item_id FROM inventory WHERE item_id = 1 FOR UPDATE;
WITH released AS (
    UPDATE stock_hold SET state = 'cancelled'
    WHERE item_id = 1 AND hold_id = 10 AND state = 'held'
    RETURNING item_id, quantity
)
UPDATE inventory AS i SET available = i.available + r.quantity
FROM released AS r WHERE i.item_id = r.item_id;
COMMIT;
-- Insufficient availability inserts no hold and changes no counter.
WITH taken AS (
    UPDATE inventory SET available = available - 4
    WHERE item_id = 1 AND available >= 4 RETURNING item_id
)
INSERT INTO stock_hold
SELECT 11, item_id, 4, 'held', clock_timestamp() + interval '10 minutes' FROM taken;
DO $$ BEGIN
    IF (SELECT available FROM inventory WHERE item_id = 1) <> 3
       OR EXISTS (SELECT 1 FROM stock_hold WHERE hold_id = 11) THEN
        RAISE EXCEPTION 'release or insufficient-stock handling failed';
    END IF;
END $$;
-- Confirm two units without restoring availability.
BEGIN;
WITH taken AS (
    UPDATE inventory SET available = available - 2
    WHERE item_id = 1 AND available >= 2 RETURNING item_id
)
INSERT INTO stock_hold
SELECT 12, item_id, 2, 'held', clock_timestamp() + interval '10 minutes' FROM taken;
COMMIT;
BEGIN;
SELECT item_id FROM inventory WHERE item_id = 1 FOR UPDATE;
UPDATE stock_hold SET state = 'confirmed'
WHERE item_id = 1 AND hold_id = 12 AND state = 'held'
  AND expires_at > clock_timestamp();
COMMIT;
-- Persist a third hold whose worker has abandoned it, then expire it.
BEGIN;
WITH taken AS (
    UPDATE inventory SET available = available - 1
    WHERE item_id = 1 AND available >= 1 RETURNING item_id
)
INSERT INTO stock_hold
SELECT 13, item_id, 1, 'held', clock_timestamp() - interval '1 second' FROM taken;
COMMIT;
BEGIN;
SELECT item_id FROM inventory WHERE item_id = 1 FOR UPDATE;
WITH released AS (
    UPDATE stock_hold SET state = 'expired'
    WHERE item_id = 1 AND state = 'held' AND expires_at <= clock_timestamp()
    RETURNING item_id, quantity
), totals AS (
    SELECT item_id, sum(quantity)::integer AS quantity FROM released GROUP BY item_id
)
UPDATE inventory AS i SET available = i.available + r.quantity
FROM totals AS r WHERE i.item_id = r.item_id;
COMMIT;
SELECT available FROM inventory WHERE item_id = 1;
-- One unit remains available; two were confirmed.
DO $$ BEGIN
    IF (SELECT available FROM inventory WHERE item_id = 1) <> 1
       OR (SELECT state FROM stock_hold WHERE hold_id = 12) <> 'confirmed'
       OR (SELECT state FROM stock_hold WHERE hold_id = 13) <> 'expired'
       OR (SELECT state FROM slot_hold WHERE hold_id = 2) <> 'expired' THEN
        RAISE EXCEPTION 'confirmation or expiry handling failed';
    END IF;
END $$;

RESET search_path;
DROP SCHEMA reservation_lab CASCADE;
