-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f external-reference.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA extref_example;

-- Our own key; foreign IDs never become it.
CREATE TABLE extref_example.customer (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    display_name text NOT NULL,
    email text
);

-- One row per foreign ID: the system that issued it, the namespace inside that
-- system, and the opaque value, compared byte by byte.
CREATE TABLE extref_example.customer_external_ref (
    system text COLLATE "C" NOT NULL,
    scope text COLLATE "C" NOT NULL,
    external_id text COLLATE "C" NOT NULL,
    customer_id bigint NOT NULL REFERENCES extref_example.customer (customer_id),
    linked_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customer_external_ref_pkey PRIMARY KEY (system, scope, external_id),
    CONSTRAINT customer_external_ref_id_present CHECK (external_id <> '')
);
CREATE INDEX customer_external_ref_customer_idx
    ON extref_example.customer_external_ref (customer_id);

-- A mirror of foreign data: the provider's event ID is the deduplication key.
CREATE TABLE extref_example.provider_event (
    system text COLLATE "C" NOT NULL,
    scope text COLLATE "C" NOT NULL,
    event_id text COLLATE "C" NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    CONSTRAINT provider_event_pkey PRIMARY KEY (system, scope, event_id)
);

-- First arrival: claim the mapping, and create the customer only if the claim won.
WITH claimed AS (
    INSERT INTO extref_example.customer_external_ref
        (system, scope, external_id, customer_id)
    VALUES ('stripe', 'live', 'cus_NffrFeUfNV2Hib',
            nextval(pg_get_serial_sequence('extref_example.customer', 'customer_id')))
    ON CONFLICT (system, scope, external_id) DO NOTHING
    RETURNING customer_id
)
INSERT INTO extref_example.customer (customer_id, display_name)
OVERRIDING SYSTEM VALUE
SELECT customer_id, 'Jenny Rosen' FROM claimed
RETURNING customer_id AS webhook_customer \gset
SELECT :webhook_customer = 1
   AND (SELECT count(*) FROM extref_example.customer) = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The sync job arrives second with the same ID: nothing is inserted anywhere,
-- and a separate statement reads the winner's mapping.
WITH claimed AS (
    INSERT INTO extref_example.customer_external_ref
        (system, scope, external_id, customer_id)
    VALUES ('stripe', 'live', 'cus_NffrFeUfNV2Hib',
            nextval(pg_get_serial_sequence('extref_example.customer', 'customer_id')))
    ON CONFLICT (system, scope, external_id) DO NOTHING
    RETURNING customer_id
)
INSERT INTO extref_example.customer (customer_id, display_name)
OVERRIDING SYSTEM VALUE
SELECT customer_id, 'Jenny Rosen' FROM claimed;
SELECT (SELECT count(*) FROM extref_example.customer) = 1
   AND (SELECT count(*) FROM extref_example.customer_external_ref) = 1
   AND (SELECT customer_id FROM extref_example.customer_external_ref
        WHERE system = 'stripe' AND scope = 'live'
          AND external_id = 'cus_NffrFeUfNV2Hib') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The same string under another scope is a different mapping; a sandbox link
-- never answers a live lookup. The losing claim above consumed value 2.
INSERT INTO extref_example.customer (display_name) VALUES ('Sandbox tester');
INSERT INTO extref_example.customer_external_ref (system, scope, external_id, customer_id)
SELECT 'stripe', 'sandbox', 'cus_NffrFeUfNV2Hib', customer_id
FROM extref_example.customer WHERE display_name = 'Sandbox tester';
SELECT (SELECT customer_id FROM extref_example.customer_external_ref
        WHERE system = 'stripe' AND scope = 'live'
          AND external_id = 'cus_NffrFeUfNV2Hib') = 1
   AND (SELECT customer_id FROM extref_example.customer_external_ref
        WHERE system = 'stripe' AND scope = 'sandbox'
          AND external_id = 'cus_NffrFeUfNV2Hib') = 3
   AND NOT EXISTS (SELECT FROM extref_example.customer WHERE customer_id = 2) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- OIDC: the issuer is the scope and sub is the ID. Equal sub values from two
-- issuers are two people; a changed e-mail does not touch the login.
INSERT INTO extref_example.customer_external_ref (system, scope, external_id, customer_id)
VALUES ('oidc', 'https://server.example.com', '248289761001', 1),
       ('oidc', 'https://login.example.org', '248289761001', 3);
UPDATE extref_example.customer SET email = 'jenny@example.com' WHERE customer_id = 1;
UPDATE extref_example.customer SET email = 'jenny.rosen@example.net' WHERE customer_id = 1;
SELECT (SELECT customer_id FROM extref_example.customer_external_ref
        WHERE system = 'oidc' AND scope = 'https://server.example.com'
          AND external_id = '248289761001') = 1
   AND (SELECT customer_id FROM extref_example.customer_external_ref
        WHERE system = 'oidc' AND scope = 'https://login.example.org'
          AND external_id = '248289761001') = 3 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A second mapping for the same scoped ID is rejected, whichever customer it names.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO extref_example.customer_external_ref (system, scope, external_id, customer_id)
VALUES ('stripe', 'live', 'cus_NffrFeUfNV2Hib', 3);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An empty string is not an ID.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO extref_example.customer_external_ref (system, scope, external_id, customer_id)
VALUES ('crm', 'eu', '', 1);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Opaque means byte comparison: IDs that differ only in case are different IDs,
-- and leading zeros survive.
INSERT INTO extref_example.customer (display_name) VALUES ('Upper'), ('Lower');
INSERT INTO extref_example.customer_external_ref (system, scope, external_id, customer_id)
SELECT 'stripe', 'live', 'cus_Q8sZ' || CASE display_name WHEN 'Upper' THEN 'A' ELSE 'a' END,
       customer_id
FROM extref_example.customer WHERE display_name IN ('Upper', 'Lower');
INSERT INTO extref_example.customer_external_ref (system, scope, external_id, customer_id)
VALUES ('crm', 'eu', '007', 1);
SELECT (SELECT count(*) FROM extref_example.customer_external_ref
        WHERE external_id IN ('cus_Q8sZA', 'cus_Q8sZa')) = 2
   AND NOT EXISTS (SELECT FROM extref_example.customer_external_ref
                   WHERE system = 'crm' AND external_id = '7') AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A case-insensitive collation would merge those two IDs into one key.
CREATE COLLATION extref_example.case_insensitive
    (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
CREATE TABLE extref_example.folded_ref (
    external_id text COLLATE extref_example.case_insensitive PRIMARY KEY
);
INSERT INTO extref_example.folded_ref VALUES ('cus_Q8sZA');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO extref_example.folded_ref VALUES ('cus_Q8sZa');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The webhook inbox: a redelivered event inserts nothing.
INSERT INTO extref_example.provider_event (system, scope, event_id, event_type, payload)
VALUES ('stripe', 'live', 'evt_1NG8Du2eZvKYlo2CUI79vXWy', 'customer.created',
        '{"object": {"id": "cus_NffrFeUfNV2Hib"}}')
ON CONFLICT (system, scope, event_id) DO NOTHING
RETURNING event_id AS first_delivery \gset
INSERT INTO extref_example.provider_event (system, scope, event_id, event_type, payload)
VALUES ('stripe', 'live', 'evt_1NG8Du2eZvKYlo2CUI79vXWy', 'customer.created',
        '{"object": {"id": "cus_NffrFeUfNV2Hib"}}')
ON CONFLICT (system, scope, event_id) DO NOTHING;
SELECT :'first_delivery' = 'evt_1NG8Du2eZvKYlo2CUI79vXWy'
   AND (SELECT count(*) FROM extref_example.provider_event) = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- One system in one fixed scope: a dedicated nullable unique column is enough.
CREATE TABLE extref_example.billing_profile (
    billing_profile_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stripe_customer_id text COLLATE "C" UNIQUE
        CHECK (stripe_customer_id <> '')
);
INSERT INTO extref_example.billing_profile (stripe_customer_id)
VALUES (NULL), (NULL), ('cus_NffrFeUfNV2Hib');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO extref_example.billing_profile (stripe_customer_id)
VALUES ('cus_NffrFeUfNV2Hib');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505'
   AND (SELECT count(*) FROM extref_example.billing_profile) = 3 AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A foreign ID cannot be written into our identity column by accident.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO extref_example.customer (customer_id, display_name) VALUES (42, 'Imported');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '428C9' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
