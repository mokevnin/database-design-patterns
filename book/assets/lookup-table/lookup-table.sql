-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f lookup-table.sql in an empty database.
-- Expected errors are checked by SQLSTATE; all lab objects roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA lookup_example;
REVOKE ALL ON SCHEMA lookup_example FROM PUBLIC;

CREATE TABLE lookup_example.order_status (
    code text PRIMARY KEY,
    label text NOT NULL CHECK (btrim(label) <> ''),
    sort_order integer NOT NULL,
    is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE lookup_example.sales_order (
    order_id bigint PRIMARY KEY,
    status_code text NOT NULL,
    CONSTRAINT sales_order_status_fk FOREIGN KEY (status_code)
        REFERENCES lookup_example.order_status (code) ON DELETE RESTRICT
);
CREATE INDEX sales_order_status_idx
    ON lookup_example.sales_order (status_code);

CREATE FUNCTION lookup_example.require_active_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    active boolean;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.status_code IS NOT DISTINCT FROM OLD.status_code THEN
            RETURN NEW;
        END IF;
    END IF;
    SELECT s.is_active INTO active
    FROM lookup_example.order_status AS s
    WHERE s.code = NEW.status_code FOR SHARE;
    IF FOUND AND NOT active THEN
        RAISE EXCEPTION 'order status is retired: %', NEW.status_code
            USING ERRCODE = '23514',
                  CONSTRAINT = 'sales_order_status_active';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION lookup_example.require_active_status() FROM PUBLIC;
CREATE TRIGGER sales_order_active_status
BEFORE INSERT OR UPDATE OF status_code ON lookup_example.sales_order
FOR EACH ROW EXECUTE FUNCTION lookup_example.require_active_status();

INSERT INTO lookup_example.order_status (code, label, sort_order)
VALUES ('draft', 'Draft', 10), ('paid', 'Paid', 20);
INSERT INTO lookup_example.sales_order VALUES (1001, 'draft'), (1002, 'draft');
UPDATE lookup_example.order_status SET label = 'Awaiting payment'
WHERE code = 'draft';
INSERT INTO lookup_example.order_status (code, label, sort_order)
VALUES ('review', 'Manual review', 15);
UPDATE lookup_example.sales_order SET status_code = 'review' WHERE order_id = 1001;
UPDATE lookup_example.order_status SET is_active = false WHERE code = 'draft';

SELECT code, label FROM lookup_example.order_status
WHERE is_active ORDER BY sort_order, code;
SELECT o.order_id, o.status_code, s.label, s.is_active
FROM lookup_example.sales_order AS o
JOIN lookup_example.order_status AS s ON s.code = o.status_code
ORDER BY o.order_id;
-- (1001, review, Manual review, true), (1002, draft, Awaiting payment, false).

SAVEPOINT unknown_code;
\set ON_ERROR_STOP off
UPDATE lookup_example.sales_order SET status_code = 'unknown' WHERE order_id = 1001;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT unknown_code;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

SAVEPOINT retired_code;
\set ON_ERROR_STOP off
INSERT INTO lookup_example.sales_order VALUES (1003, 'draft');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT retired_code;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

-- Re-saving an unchanged retired status remains permitted.
UPDATE lookup_example.sales_order SET status_code = 'draft' WHERE order_id = 1002;
SAVEPOINT referenced_code;
\set ON_ERROR_STOP off
DELETE FROM lookup_example.order_status WHERE code = 'draft';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT referenced_code;
SELECT :'rejected_state' = '23001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0;
\endif

-- Independent alternatives, not additional constraints on sales_order.
CREATE TYPE lookup_example.fixed_status AS ENUM ('draft', 'paid');
CREATE TABLE lookup_example.enum_order (
    order_id bigint PRIMARY KEY,
    status lookup_example.fixed_status NOT NULL
);
CREATE TABLE lookup_example.checked_order (
    order_id bigint PRIMARY KEY,
    status text NOT NULL CHECK (status IN ('draft', 'paid'))
);
CREATE DOMAIN lookup_example.status_domain AS text
    CHECK (VALUE IN ('draft', 'paid'));
CREATE TABLE lookup_example.domain_order (
    order_id bigint PRIMARY KEY,
    status lookup_example.status_domain NOT NULL
);
INSERT INTO lookup_example.enum_order VALUES (1, 'draft');
INSERT INTO lookup_example.checked_order VALUES (1, 'draft');
INSERT INTO lookup_example.domain_order VALUES (1, 'draft');
SELECT (SELECT status_code = 'review' FROM lookup_example.sales_order WHERE order_id = 1001)
    AND (SELECT status_code = 'draft' FROM lookup_example.sales_order WHERE order_id = 1002)
    AND (SELECT count(*) = 2 FROM lookup_example.sales_order) AS valid \gset
\if :valid
\else
    SELECT 1 / 0;
\endif
ROLLBACK;
