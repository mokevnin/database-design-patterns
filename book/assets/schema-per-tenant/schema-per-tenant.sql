-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -v ON_ERROR_STOP=1 -f schema-per-tenant.sql in a fresh lab database.
-- Requires a superuser for provisioning. LOGIN roles have no passwords: local lab only.
\set ON_ERROR_STOP on
CREATE ROLE st_owner NOLOGIN;
CREATE ROLE st_app_a LOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE st_app_b LOGIN NOSUPERUSER NOBYPASSRLS;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SELECT format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database()) \gexec
CREATE SCHEMA tenant_a AUTHORIZATION st_owner;
CREATE SCHEMA tenant_b AUTHORIZATION st_owner;
SET ROLE st_owner;
CREATE TABLE tenant_a.customer (
    customer_id bigint PRIMARY KEY,
    customer_number text NOT NULL UNIQUE,
    display_name text NOT NULL
);
CREATE TABLE tenant_a.customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    description text NOT NULL,
    CONSTRAINT order_customer_fk FOREIGN KEY (customer_id)
        REFERENCES tenant_a.customer (customer_id)
);
CREATE INDEX order_customer_idx ON tenant_a.customer_order (customer_id);
CREATE TABLE tenant_a.schema_migration (
    version integer PRIMARY KEY CHECK (version > 0)
);
CREATE TABLE tenant_b.customer (
    customer_id bigint PRIMARY KEY,
    customer_number text NOT NULL UNIQUE,
    display_name text NOT NULL
);
CREATE TABLE tenant_b.customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    description text NOT NULL,
    CONSTRAINT order_customer_fk FOREIGN KEY (customer_id)
        REFERENCES tenant_b.customer (customer_id)
);
CREATE INDEX order_customer_idx ON tenant_b.customer_order (customer_id);
CREATE TABLE tenant_b.schema_migration (
    version integer PRIMARY KEY CHECK (version > 0)
);
INSERT INTO tenant_a.schema_migration VALUES (1);
INSERT INTO tenant_b.schema_migration VALUES (1);
GRANT USAGE ON SCHEMA tenant_a TO st_app_a;
GRANT USAGE ON SCHEMA tenant_b TO st_app_b;
GRANT SELECT, INSERT, UPDATE, DELETE ON tenant_a.customer, tenant_a.customer_order TO st_app_a;
GRANT SELECT, INSERT, UPDATE, DELETE ON tenant_b.customer, tenant_b.customer_order TO st_app_b;
GRANT SELECT ON tenant_a.schema_migration TO st_app_a;
GRANT SELECT ON tenant_b.schema_migration TO st_app_b;
RESET ROLE;
SET ROLE st_app_a;
BEGIN;
SET LOCAL search_path = pg_catalog, tenant_a;
INSERT INTO customer VALUES (10, 'C-10', 'Acme customer');
INSERT INTO customer_order VALUES (100, 10, 'First order');
UPDATE customer SET display_name = 'Acme renamed' WHERE customer_id = 10;
SELECT o.order_id, c.display_name
FROM customer_order AS o JOIN customer AS c USING (customer_id);
DO $$ BEGIN
    BEGIN
        SELECT count(*) FROM tenant_b.customer;
        RAISE EXCEPTION 'expected schema permission rejection';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO customer_order VALUES (101, 20, 'Missing customer');
        RAISE EXCEPTION 'expected foreign-key rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
COMMIT;
RESET ROLE;
SET ROLE st_app_b;
BEGIN;
SET LOCAL search_path = pg_catalog, tenant_b;
INSERT INTO customer VALUES (10, 'C-10', 'Birch customer');
INSERT INTO customer_order VALUES (100, 10, 'Independent order');
SELECT o.order_id, c.display_name
FROM customer_order AS o JOIN customer AS c USING (customer_id);
DO $$ BEGIN
    IF (SELECT count(*) FROM customer) <> 1 THEN
        RAISE EXCEPTION 'wrong schema contents';
    END IF;
END $$;
COMMIT;
RESET ROLE;
-- Per-schema migration: DDL and version marker commit together.
SET ROLE st_owner;
BEGIN;
SELECT pg_advisory_xact_lock(71001);
ALTER TABLE tenant_a.customer ADD COLUMN billing_note text;
INSERT INTO tenant_a.schema_migration VALUES (2);
COMMIT;
BEGIN;
SELECT pg_advisory_xact_lock(71002);
ALTER TABLE tenant_b.customer ADD COLUMN billing_note text;
INSERT INTO tenant_b.schema_migration VALUES (2);
COMMIT;
RESET ROLE;
SELECT 'tenant_a' AS tenant, max(version) FROM tenant_a.schema_migration
UNION ALL
SELECT 'tenant_b', max(version) FROM tenant_b.schema_migration;
