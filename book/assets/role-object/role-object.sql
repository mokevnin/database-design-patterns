-- Checked on PostgreSQL 18.6 (Homebrew).
-- All role periods in this example are business dates, [start, end).
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA role_example;
SET search_path = role_example, public;

CREATE TABLE party (
    party_id bigint PRIMARY KEY,
    display_name text NOT NULL
);
CREATE TABLE party_role (
    role_id bigint PRIMARY KEY,
    party_id bigint NOT NULL REFERENCES party (party_id),
    role_type text NOT NULL CHECK (role_type IN ('customer', 'supplier', 'employee', 'account_manager')),
    valid_at daterange NOT NULL CHECK (NOT isempty(valid_at) AND NOT lower_inf(valid_at)),
    conflict_group text GENERATED ALWAYS AS
        (CASE WHEN role_type IN ('supplier', 'employee') THEN 'procurement' ELSE role_type END) STORED,
    UNIQUE (role_id, role_type),
    CONSTRAINT role_no_conflict EXCLUDE USING gist
        (party_id WITH =, conflict_group WITH =, valid_at WITH &&)
);
CREATE TABLE customer_terms (
    role_id bigint PRIMARY KEY,
    role_type text NOT NULL DEFAULT 'customer' CHECK (role_type = 'customer'),
    credit_limit numeric(14,2) NOT NULL CHECK (credit_limit >= 0 AND credit_limit < 'Infinity'::numeric),
    currency text NOT NULL,
    FOREIGN KEY (role_id, role_type) REFERENCES party_role (role_id, role_type)
);
CREATE TABLE role_relationship (
    customer_role_id bigint PRIMARY KEY,
    customer_type text NOT NULL DEFAULT 'customer' CHECK (customer_type = 'customer'),
    manager_role_id bigint NOT NULL,
    manager_type text NOT NULL DEFAULT 'account_manager' CHECK (manager_type = 'account_manager'),
    FOREIGN KEY (customer_role_id, customer_type) REFERENCES party_role (role_id, role_type),
    FOREIGN KEY (manager_role_id, manager_type) REFERENCES party_role (role_id, role_type)
);
CREATE INDEX role_relationship_manager_idx ON role_relationship (manager_role_id);

INSERT INTO party VALUES (1, 'Northwind'), (2, 'Ada');
INSERT INTO party_role (role_id, party_id, role_type, valid_at) VALUES
    (10, 1, 'customer', '[2026-01-01,)'),
    (11, 1, 'supplier', '[2026-01-01,2026-07-01)'),
    (12, 1, 'employee', '[2026-07-01,)'),
    (20, 2, 'account_manager', '[2026-01-01,)');
INSERT INTO customer_terms (role_id, credit_limit, currency) VALUES (10, 5000, 'EUR');
INSERT INTO role_relationship (customer_role_id, manager_role_id) VALUES (10, 20);
SELECT role_type FROM party_role
WHERE party_id = 1 AND valid_at @> DATE '2026-08-01' ORDER BY role_type;
SELECT c.party_id AS customer, m.party_id AS manager
FROM role_relationship AS r
JOIN party_role AS c ON c.role_id = r.customer_role_id
JOIN party_role AS m ON m.role_id = r.manager_role_id
WHERE c.valid_at @> DATE '2026-08-01' AND m.valid_at @> DATE '2026-08-01';

BEGIN;
SELECT party_id FROM party WHERE party_id = 1 FOR UPDATE;
UPDATE party_role SET valid_at = '[2026-01-01,2027-01-01)' WHERE role_id = 10;
INSERT INTO party_role (role_id, party_id, role_type, valid_at)
VALUES (13, 1, 'customer', '[2027-01-01,)');
INSERT INTO customer_terms (role_id, credit_limit, currency) VALUES (13, 6000, 'EUR');
COMMIT;
DO $$
BEGIN
    BEGIN
        INSERT INTO party_role (role_id, party_id, role_type, valid_at)
        VALUES (14, 1, 'supplier', '[2026-06-01,2026-08-01)');
        RAISE EXCEPTION 'expected role conflict';
    EXCEPTION WHEN exclusion_violation THEN
        IF SQLERRM NOT LIKE '%role_no_conflict%' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT (SELECT count(*) FROM party_role WHERE party_id = 1
            AND valid_at @> DATE '2026-08-01') = 2;
END $$;
