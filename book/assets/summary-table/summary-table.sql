-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -f summary-table.sql in an empty database.
-- Intentional errors are checked by SQLSTATE; unexpected failures stop the script.
-- Creates the isolated summary_table_example schema and leaves it for inspection.
\set ON_ERROR_STOP on
CREATE SCHEMA summary_table_example;
SET search_path = summary_table_example, public;

CREATE TABLE shop (
    shop_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE sale (
    sale_id bigint PRIMARY KEY,
    shop_id bigint NOT NULL REFERENCES shop (shop_id),
    business_day date NOT NULL,
    amount_cents bigint NOT NULL CHECK (amount_cents >= 0)
);
CREATE INDEX sale_group_idx ON sale (shop_id, business_day);
CREATE TABLE daily_sale (
    shop_id bigint REFERENCES shop (shop_id),
    business_day date,
    sale_count bigint NOT NULL CHECK (sale_count >= 0),
    total_cents numeric NOT NULL CHECK (total_cents >= 0),
    PRIMARY KEY (shop_id, business_day)
);
INSERT INTO shop VALUES (1, 'Harbor');

WITH added AS (
    INSERT INTO sale VALUES
        (101, 1, DATE '2026-11-01', 1200),
        (102, 1, DATE '2026-11-01', 800)
    RETURNING shop_id, business_day, amount_cents
)
INSERT INTO daily_sale AS d
SELECT shop_id, business_day, count(*), sum(amount_cents)
FROM added GROUP BY shop_id, business_day
ON CONFLICT (shop_id, business_day) DO UPDATE
SET sale_count = d.sale_count + EXCLUDED.sale_count,
    total_cents = d.total_cents + EXCLUDED.total_cents;
SELECT * FROM daily_sale;

SELECT (SELECT sale_count = 2 AND total_cents = 2000 FROM daily_sale) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


WITH changed AS (
    UPDATE sale SET amount_cents = 1500 WHERE sale_id = 101
    RETURNING WITH (OLD AS o, NEW AS n)
        n.shop_id, n.business_day, n.amount_cents - o.amount_cents AS delta
)
UPDATE daily_sale AS d SET total_cents = d.total_cents + c.delta
FROM changed AS c
WHERE (d.shop_id, d.business_day) = (c.shop_id, c.business_day)
RETURNING d.*;

SELECT (SELECT sale_count = 2 AND total_cents = 2300 FROM daily_sale) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


WITH removed AS (
    DELETE FROM sale WHERE sale_id = 102
    RETURNING shop_id, business_day, amount_cents
)
UPDATE daily_sale AS d
SET sale_count = d.sale_count - 1,
    total_cents = d.total_cents - r.amount_cents
FROM removed AS r
WHERE (d.shop_id, d.business_day) = (r.shop_id, r.business_day)
RETURNING d.*;

SELECT (SELECT sale_count = 1 AND total_cents = 1500 FROM daily_sale) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


BEGIN;
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO sale VALUES (101, 1, DATE '2026-11-01', 1500);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT (SELECT :'rejected_state' = '23505') AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif
COMMIT;


CREATE MATERIALIZED VIEW daily_sale_snapshot AS
SELECT shop_id, business_day, count(*) AS sale_count,
       sum(amount_cents) AS total_cents
FROM sale GROUP BY shop_id, business_day;
CREATE UNIQUE INDEX daily_sale_snapshot_key
    ON daily_sale_snapshot (shop_id, business_day);
REFRESH MATERIALIZED VIEW CONCURRENTLY daily_sale_snapshot;

WITH expected AS (
    SELECT shop_id, business_day, count(*) AS sale_count,
           sum(amount_cents) AS total_cents
    FROM sale GROUP BY shop_id, business_day
)
SELECT shop_id, business_day
FROM expected AS e FULL JOIN daily_sale AS d USING (shop_id, business_day)
WHERE coalesce(e.sale_count, 0) <> coalesce(d.sale_count, 0)
   OR coalesce(e.total_cents, 0) <> coalesce(d.total_cents, 0);

BEGIN;
LOCK TABLE sale IN SHARE MODE;
LOCK TABLE daily_sale IN EXCLUSIVE MODE;
DELETE FROM daily_sale;
INSERT INTO daily_sale
SELECT shop_id, business_day, count(*), sum(amount_cents)
FROM sale GROUP BY shop_id, business_day;
COMMIT;

SELECT (SELECT sale_count = 1 AND total_cents = 1500 FROM daily_sale) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


-- Simulate drift that passes the local nonnegative checks.
UPDATE daily_sale SET total_cents = 9999;

WITH expected AS (
    SELECT shop_id, business_day, count(*) AS sale_count,
           sum(amount_cents) AS total_cents
    FROM sale GROUP BY shop_id, business_day
)
SELECT shop_id, business_day
FROM expected AS e FULL JOIN daily_sale AS d USING (shop_id, business_day)
WHERE coalesce(e.sale_count, 0) <> coalesce(d.sale_count, 0)
   OR coalesce(e.total_cents, 0) <> coalesce(d.total_cents, 0);

BEGIN;
LOCK TABLE sale IN SHARE MODE;
LOCK TABLE daily_sale IN EXCLUSIVE MODE;
DELETE FROM daily_sale;
INSERT INTO daily_sale
SELECT shop_id, business_day, count(*), sum(amount_cents)
FROM sale GROUP BY shop_id, business_day;
COMMIT;

SELECT (SELECT sale_count = 1 AND total_cents = 1500 FROM daily_sale) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


-- Removing the final sale leaves an allowed zero group.
WITH removed AS (
    DELETE FROM sale WHERE sale_id = 101
    RETURNING shop_id, business_day, amount_cents
)
UPDATE daily_sale AS d
SET sale_count = d.sale_count - 1, total_cents = d.total_cents - r.amount_cents
FROM removed AS r
WHERE (d.shop_id, d.business_day) = (r.shop_id, r.business_day);

SELECT (SELECT sale_count = 0 AND total_cents = 0 FROM daily_sale) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif


WITH expected AS (
    SELECT shop_id, business_day, count(*) AS sale_count,
           sum(amount_cents) AS total_cents
    FROM sale GROUP BY shop_id, business_day
)
SELECT shop_id, business_day
FROM expected AS e FULL JOIN daily_sale AS d USING (shop_id, business_day)
WHERE coalesce(e.sale_count, 0) <> coalesce(d.sale_count, 0)
   OR coalesce(e.total_cents, 0) <> coalesce(d.total_cents, 0);

REFRESH MATERIALIZED VIEW CONCURRENTLY daily_sale_snapshot;

SELECT (SELECT NOT EXISTS (SELECT FROM daily_sale_snapshot)) AS verified \gset
\if :verified
\else
    \echo 'Assertion failed'
    \quit 1
\endif

