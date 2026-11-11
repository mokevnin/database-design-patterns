-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -v ON_ERROR_STOP=1 -f shared-schema.sql in a fresh lab database.
-- Requires a superuser for lab provisioning; runtime uses ss_app without ownership.
\set ON_ERROR_STOP on
CREATE ROLE ss_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE SCHEMA ss;
CREATE TABLE ss.tenant (
    tenant_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE ss.customer (
    tenant_id bigint NOT NULL REFERENCES ss.tenant (tenant_id),
    customer_id bigint NOT NULL,
    customer_number text NOT NULL,
    display_name text NOT NULL,
    PRIMARY KEY (tenant_id, customer_id),
    UNIQUE (tenant_id, customer_number)
);
CREATE TABLE ss.customer_order (
    tenant_id bigint NOT NULL,
    order_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    description text NOT NULL,
    PRIMARY KEY (tenant_id, order_id),
    CONSTRAINT order_customer_fk FOREIGN KEY (tenant_id, customer_id)
        REFERENCES ss.customer (tenant_id, customer_id)
);
CREATE INDEX order_customer_idx ON ss.customer_order (tenant_id, customer_id);
INSERT INTO ss.tenant VALUES (1, 'Acme'), (2, 'Birch');
INSERT INTO ss.customer VALUES
    (1, 10, 'C-10', 'Acme customer'),
    (2, 10, 'C-10', 'Birch customer'),
    (2, 20, 'C-20', 'Birch only');
ALTER TABLE ss.customer ENABLE ROW LEVEL SECURITY;
ALTER TABLE ss.customer FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ss.customer TO ss_app
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::bigint)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::bigint);
ALTER TABLE ss.customer_order ENABLE ROW LEVEL SECURITY;
ALTER TABLE ss.customer_order FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ss.customer_order TO ss_app
    USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::bigint)
    WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::bigint);
GRANT USAGE ON SCHEMA ss TO ss_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ss.customer, ss.customer_order TO ss_app;
SET ROLE ss_app;
-- Missing context exposes no customer rows.
DO $$ BEGIN
    IF (SELECT count(*) FROM ss.customer) <> 0 THEN
        RAISE EXCEPTION 'missing context exposed rows';
    END IF;
END $$;
BEGIN;
SET LOCAL app.tenant_id = '1';
INSERT INTO ss.customer_order VALUES (1, 100, 10, 'First order');
SELECT tenant_id, customer_id, customer_number FROM ss.customer;
UPDATE ss.customer SET display_name = 'Acme renamed'
WHERE tenant_id = 1 AND customer_id = 10;
SELECT o.order_id, c.display_name
FROM ss.customer_order AS o
JOIN ss.customer AS c USING (tenant_id, customer_id);
-- The DO blocks execute the invalid statements and assert their SQLSTATE.
DO $$ BEGIN
    BEGIN
        INSERT INTO ss.customer_order VALUES (1, 101, 20, 'Wrong tenant');
        RAISE EXCEPTION 'expected foreign-key rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO ss.customer_order VALUES (2, 102, 10, 'Forged scope');
        RAISE EXCEPTION 'expected RLS rejection';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    IF (SELECT count(*) FROM ss.customer) <> 1 THEN
        RAISE EXCEPTION 'tenant 1 visibility incorrect';
    END IF;
END $$;
COMMIT;
-- Transaction-local setting has gone; nullif also handles its empty reset value.
DO $$ BEGIN
    IF (SELECT count(*) FROM ss.customer) <> 0 THEN
        RAISE EXCEPTION 'context leaked after commit';
    END IF;
END $$;
BEGIN;
SET LOCAL app.tenant_id = '2';
SELECT tenant_id, customer_id, customer_number FROM ss.customer ORDER BY customer_id;
DO $$ BEGIN
    IF (SELECT count(*) FROM ss.customer) <> 2 THEN
        RAISE EXCEPTION 'tenant 2 visibility incorrect';
    END IF;
    IF (SELECT count(*) FROM ss.customer_order) <> 0 THEN
        RAISE EXCEPTION 'tenant 1 order exposed';
    END IF;
END $$;
ROLLBACK;
RESET ROLE;
