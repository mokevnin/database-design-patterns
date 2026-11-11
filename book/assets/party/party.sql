-- Checked on PostgreSQL 18.6 (Homebrew).
-- Run with psql -X -v ON_ERROR_STOP=1 -f party.sql in a fresh database.
\set ON_ERROR_STOP on
CREATE SCHEMA party_example;
SET search_path = party_example, public;

CREATE TABLE party (
    party_id bigint PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('person', 'organization')),
    display_name text NOT NULL,
    UNIQUE (party_id, kind)
);
CREATE TABLE person (
    party_id bigint PRIMARY KEY,
    kind text NOT NULL DEFAULT 'person' CHECK (kind = 'person'),
    given_name text NOT NULL,
    family_name text NOT NULL,
    CONSTRAINT person_party_kind_fk FOREIGN KEY (party_id, kind)
        REFERENCES party (party_id, kind)
);
CREATE TABLE organization (
    party_id bigint PRIMARY KEY,
    kind text NOT NULL DEFAULT 'organization' CHECK (kind = 'organization'),
    registry text NOT NULL,
    registration_number text NOT NULL,
    CONSTRAINT organization_registration_key UNIQUE (registry, registration_number),
    FOREIGN KEY (party_id, kind) REFERENCES party (party_id, kind)
);
CREATE TABLE party_contact (
    party_id bigint REFERENCES party (party_id),
    channel text CHECK (channel IN ('email', 'phone', 'postal')),
    contact_value text NOT NULL,
    PRIMARY KEY (party_id, channel, contact_value)
);
CREATE TABLE party_relationship (
    from_party_id bigint REFERENCES party (party_id),
    to_party_id bigint REFERENCES party (party_id),
    relationship_type text CHECK (relationship_type IN ('contact_for', 'subsidiary_of')),
    PRIMARY KEY (from_party_id, to_party_id, relationship_type),
    CHECK (from_party_id <> to_party_id)
);
CREATE INDEX party_relationship_target_idx ON party_relationship (to_party_id);

BEGIN;
INSERT INTO party VALUES (1, 'organization', 'Northwind'), (2, 'person', 'Ada Lee');
INSERT INTO organization (party_id, registry, registration_number) VALUES (1, 'demo-registry', 'N-17');
INSERT INTO person (party_id, given_name, family_name) VALUES (2, 'Ada', 'Lee');
INSERT INTO party_contact VALUES (1, 'email', 'orders@example.com');
INSERT INTO party_relationship VALUES (2, 1, 'contact_for');
COMMIT;
SELECT p.display_name, c.contact_value
FROM party AS p JOIN party_contact AS c USING (party_id) WHERE p.party_id = 1;
UPDATE party SET display_name = 'Northwind Trading' WHERE party_id = 1;
SELECT p.display_name, o.registration_number
FROM party AS p JOIN organization AS o USING (party_id);

DO $$
BEGIN
    BEGIN
        INSERT INTO person (party_id, given_name, family_name) VALUES (1, 'Wrong', 'Type');
        RAISE EXCEPTION 'expected type mismatch';
    EXCEPTION WHEN foreign_key_violation THEN
        IF SQLERRM NOT LIKE '%person_party_kind_fk%' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT (SELECT count(*) FROM person) = 1;
    BEGIN
        INSERT INTO party VALUES (3, 'organization', 'Duplicate');
        INSERT INTO organization (party_id, registry, registration_number)
        VALUES (3, 'demo-registry', 'N-17');
        RAISE EXCEPTION 'expected duplicate registration';
    EXCEPTION WHEN unique_violation THEN
        IF SQLERRM NOT LIKE '%organization_registration_key%' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT NOT EXISTS (SELECT FROM party WHERE party_id = 3);
END $$;
