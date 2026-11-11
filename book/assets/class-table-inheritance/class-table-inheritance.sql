-- Checked on PostgreSQL 18.6. Run with psql -X -v ON_ERROR_STOP=1 -f this-file.sql.
-- Deferred checks are forced inside subtransactions to assert expected failures.
BEGIN;
CREATE SCHEMA class_lab;
SET LOCAL search_path = class_lab, public;

CREATE TABLE customer (
    customer_id bigint PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('person', 'company')),
    display_name text NOT NULL,
    person_id bigint GENERATED ALWAYS AS
        (CASE WHEN kind = 'person' THEN customer_id END) STORED,
    company_id bigint GENERATED ALWAYS AS
        (CASE WHEN kind = 'company' THEN customer_id END) STORED,
    UNIQUE (customer_id, kind)
);
CREATE TABLE person (
    customer_id bigint PRIMARY KEY,
    kind text NOT NULL DEFAULT 'person' CHECK (kind = 'person'),
    birth_date date NOT NULL,
    FOREIGN KEY (customer_id, kind) REFERENCES customer (customer_id, kind)
        ON DELETE CASCADE
);
CREATE TABLE company (
    customer_id bigint PRIMARY KEY,
    kind text NOT NULL DEFAULT 'company' CHECK (kind = 'company'),
    registration_number text NOT NULL UNIQUE,
    FOREIGN KEY (customer_id, kind) REFERENCES customer (customer_id, kind)
        ON DELETE CASCADE
);
ALTER TABLE customer ADD CONSTRAINT customer_requires_person
    FOREIGN KEY (person_id) REFERENCES person (customer_id)
    DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE customer ADD CONSTRAINT customer_requires_company
    FOREIGN KEY (company_id) REFERENCES company (customer_id)
    DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);

INSERT INTO customer (customer_id, kind, display_name) VALUES (1, 'person', 'Ada');
INSERT INTO person (customer_id, birth_date) VALUES (1, DATE '1990-01-01');
INSERT INTO customer_order VALUES (10, 1);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT c.customer_id, c.display_name, p.birth_date
FROM customer AS c JOIN person AS p USING (customer_id);
DO $$
BEGIN
    BEGIN
        INSERT INTO customer (customer_id, kind, display_name)
        VALUES (2, 'company', 'Incomplete');
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Expected missing subtype rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        IF SQLERRM <> 'insert or update on table "customer" violates foreign key constraint "customer_requires_company"' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO company (customer_id, registration_number) VALUES (1, 'WRONG');
        RAISE EXCEPTION 'Expected wrong subtype rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected wrong subtype SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;

-- Convert the whole subtype in one transaction (the outer lab transaction here).
DELETE FROM person WHERE customer_id = 1;
UPDATE customer SET kind = 'company' WHERE customer_id = 1;
INSERT INTO company (customer_id, registration_number) VALUES (1, 'REG-1');
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT o.order_id, c.kind, d.registration_number
FROM customer_order AS o JOIN customer AS c USING (customer_id)
JOIN company AS d USING (customer_id);
DO $$
BEGIN
    BEGIN
        DELETE FROM company WHERE customer_id = 1;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Expected required subtype deletion rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected subtype deletion SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
DELETE FROM customer_order WHERE customer_id = 1;
DELETE FROM customer WHERE customer_id = 1;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT count(*) AS remaining_companies FROM company;
ROLLBACK;
