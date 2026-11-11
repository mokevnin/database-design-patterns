-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -v ON_ERROR_STOP=1 -d postgres -f database-per-tenant.sql.
-- Fresh throwaway cluster only; requires a superuser and creates two databases.
-- LOGIN roles have no passwords: use only the lab's local trust authentication.
\set ON_ERROR_STOP on
SELECT current_user AS lab_admin \gset
CREATE ROLE dt_owner NOLOGIN;
CREATE ROLE dt_app_a LOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE dt_app_b LOGIN NOSUPERUSER NOBYPASSRLS;
CREATE DATABASE dt_a OWNER dt_owner;
CREATE DATABASE dt_b OWNER dt_owner;
REVOKE ALL ON DATABASE dt_a, dt_b FROM PUBLIC;
GRANT CONNECT ON DATABASE dt_a TO dt_app_a;
GRANT CONNECT ON DATABASE dt_b TO dt_app_b;
CREATE SCHEMA dt_control;
CREATE TABLE dt_control.tenant_route (
    tenant_id bigint PRIMARY KEY,
    database_name text NOT NULL UNIQUE,
    route_epoch bigint NOT NULL CHECK (route_epoch > 0)
);
INSERT INTO dt_control.tenant_route VALUES (1, 'dt_a', 1), (2, 'dt_b', 1);
SELECT * FROM dt_control.tenant_route ORDER BY tenant_id;
\connect dt_a
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SET ROLE dt_owner;
CREATE SCHEMA app AUTHORIZATION dt_owner;
CREATE TABLE app.deployment_identity (
    singleton boolean PRIMARY KEY CHECK (singleton),
    tenant_id bigint NOT NULL UNIQUE,
    schema_version integer NOT NULL CHECK (schema_version > 0)
);
INSERT INTO app.deployment_identity VALUES (true, 1, 1);
CREATE TABLE app.customer (
    customer_id bigint PRIMARY KEY,
    customer_number text NOT NULL UNIQUE,
    display_name text NOT NULL
);
CREATE TABLE app.customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    description text NOT NULL,
    CONSTRAINT order_customer_fk FOREIGN KEY (customer_id)
        REFERENCES app.customer (customer_id)
);
CREATE INDEX order_customer_idx ON app.customer_order (customer_id);
GRANT USAGE ON SCHEMA app TO dt_app_a;
GRANT SELECT ON app.deployment_identity TO dt_app_a;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.customer, app.customer_order TO dt_app_a;
RESET ROLE;
\connect dt_a dt_app_a
SELECT current_database(), tenant_id, schema_version FROM app.deployment_identity;
INSERT INTO app.customer VALUES (10, 'C-10', 'Acme customer');
INSERT INTO app.customer_order VALUES (100, 10, 'First order');
UPDATE app.customer SET display_name = 'Acme renamed' WHERE customer_id = 10;
SELECT o.order_id, c.display_name
FROM app.customer_order AS o JOIN app.customer AS c USING (customer_id);
DO $$ BEGIN
    BEGIN
        INSERT INTO app.customer_order VALUES (101, 20, 'Missing customer');
        RAISE EXCEPTION 'expected foreign-key rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        SELECT * FROM dt_b.app.customer;
        RAISE EXCEPTION 'expected cross-database rejection';
    EXCEPTION WHEN feature_not_supported THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    IF has_database_privilege(current_user, 'dt_b', 'CONNECT') THEN
        RAISE EXCEPTION 'tenant A has CONNECT to tenant B';
    END IF;
END $$;
\connect dt_b :lab_admin
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SET ROLE dt_owner;
CREATE SCHEMA app AUTHORIZATION dt_owner;
CREATE TABLE app.deployment_identity (
    singleton boolean PRIMARY KEY CHECK (singleton),
    tenant_id bigint NOT NULL UNIQUE,
    schema_version integer NOT NULL CHECK (schema_version > 0)
);
INSERT INTO app.deployment_identity VALUES (true, 2, 1);
CREATE TABLE app.customer (
    customer_id bigint PRIMARY KEY,
    customer_number text NOT NULL UNIQUE,
    display_name text NOT NULL
);
CREATE TABLE app.customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    description text NOT NULL,
    CONSTRAINT order_customer_fk FOREIGN KEY (customer_id)
        REFERENCES app.customer (customer_id)
);
CREATE INDEX order_customer_idx ON app.customer_order (customer_id);
GRANT USAGE ON SCHEMA app TO dt_app_b;
GRANT SELECT ON app.deployment_identity TO dt_app_b;
GRANT SELECT, INSERT, UPDATE, DELETE ON app.customer, app.customer_order TO dt_app_b;
RESET ROLE;
\connect dt_b dt_app_b
INSERT INTO app.customer VALUES (10, 'C-10', 'Birch customer');
INSERT INTO app.customer_order VALUES (100, 10, 'Independent order');
SELECT current_database(), tenant_id, schema_version FROM app.deployment_identity;
SELECT o.order_id, c.display_name
FROM app.customer_order AS o JOIN app.customer AS c USING (customer_id);
-- The runtime role cannot rewrite its deployment identity.
DO $$ BEGIN
    BEGIN
        UPDATE app.deployment_identity SET tenant_id = 1;
        RAISE EXCEPTION 'expected identity permission rejection';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
\connect postgres :lab_admin
