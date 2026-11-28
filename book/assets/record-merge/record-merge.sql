-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f record-merge.sql in an empty disposable database.
-- The last section commits: it opens two extra connections to the same database
-- through dblink (same role, no password), creates the dblink extension in its
-- own schema and drops that schema at the end.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
BEGIN;
CREATE SCHEMA merge_example;
SET LOCAL search_path = merge_example;

-- A customer is live until it is merged; merged_into may name only a live row.
CREATE TABLE customer (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id text NOT NULL UNIQUE,
    display_name text NOT NULL,
    email text,
    merged_into bigint,
    merged_at timestamptz,
    is_live boolean GENERATED ALWAYS AS (merged_into IS NULL) STORED,
    target_live boolean
        GENERATED ALWAYS AS (CASE WHEN merged_into IS NOT NULL THEN true END) STORED,
    CONSTRAINT customer_live_key UNIQUE (customer_id, is_live),
    CONSTRAINT customer_not_self CHECK (merged_into <> customer_id),
    CONSTRAINT customer_merged_at_set CHECK ((merged_into IS NULL) = (merged_at IS NULL)),
    CONSTRAINT customer_merged_into_fkey FOREIGN KEY (merged_into, target_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE INDEX customer_merged_into_idx ON customer (merged_into);
-- Uniqueness applies to live rows only; an absorbed row keeps its old values.
CREATE UNIQUE INDEX customer_live_email_key ON customer (email) WHERE merged_into IS NULL;

-- Every child references (customer_id, true): it can point at live customers only.
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    customer_live boolean GENERATED ALWAYS AS (true) STORED,
    placed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customer_order_customer_fkey FOREIGN KEY (customer_id, customer_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);

CREATE TABLE customer_address (
    address_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    customer_live boolean GENERATED ALWAYS AS (true) STORED,
    line text NOT NULL,
    is_default boolean NOT NULL DEFAULT false,
    CONSTRAINT customer_address_customer_fkey FOREIGN KEY (customer_id, customer_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE INDEX customer_address_customer_idx ON customer_address (customer_id);
CREATE UNIQUE INDEX customer_address_one_default
    ON customer_address (customer_id) WHERE is_default;

CREATE TABLE team (
    team_id bigint PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE team_member (
    team_id bigint NOT NULL REFERENCES team (team_id),
    customer_id bigint NOT NULL,
    customer_live boolean GENERATED ALWAYS AS (true) STORED,
    joined_on date NOT NULL,
    CONSTRAINT team_member_pkey PRIMARY KEY (team_id, customer_id),
    CONSTRAINT team_member_customer_fkey FOREIGN KEY (customer_id, customer_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE INDEX team_member_customer_idx ON team_member (customer_id);

-- Foreign IDs, as in External Reference: the key does not contain customer_id.
CREATE TABLE customer_external_ref (
    system text COLLATE "C" NOT NULL,
    scope text COLLATE "C" NOT NULL,
    external_id text COLLATE "C" NOT NULL,
    customer_id bigint NOT NULL,
    customer_live boolean GENERATED ALWAYS AS (true) STORED,
    CONSTRAINT customer_external_ref_pkey PRIMARY KEY (system, scope, external_id),
    CONSTRAINT customer_external_ref_customer_fkey FOREIGN KEY (customer_id, customer_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE INDEX customer_external_ref_customer_idx ON customer_external_ref (customer_id);

-- PostgreSQL 18 makes generated columns VIRTUAL by default; those cannot carry the key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
CREATE TABLE invoice (
    invoice_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    customer_live boolean GENERATED ALWAYS AS (true),
    FOREIGN KEY (customer_id, customer_live) REFERENCES customer (customer_id, is_live)
);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '0A000' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The merge journal: one header per merge, one row per changed child row.
CREATE TABLE customer_merge (
    merge_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    absorbed_id bigint NOT NULL REFERENCES customer (customer_id),
    survivor_id bigint NOT NULL REFERENCES customer (customer_id),
    reason text NOT NULL,
    merged_at timestamptz NOT NULL DEFAULT now(),
    unmerged_at timestamptz,
    CHECK (absorbed_id <> survivor_id)
);
CREATE UNIQUE INDEX customer_merge_active_key
    ON customer_merge (absorbed_id) WHERE unmerged_at IS NULL;
CREATE TABLE customer_merge_change (
    change_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merge_id bigint NOT NULL REFERENCES customer_merge (merge_id),
    table_name text NOT NULL CHECK (table_name IN (
        'customer', 'customer_order', 'customer_address', 'team_member',
        'customer_external_ref')),
    action text NOT NULL CHECK (action IN ('repoint', 'demote', 'adjust', 'drop')),
    row_key jsonb NOT NULL,
    old_row jsonb
);
CREATE INDEX customer_merge_change_merge_idx ON customer_merge_change (merge_id);

-- One hop is enough: chains are flattened when they would form.
CREATE FUNCTION resolve_customer(p_customer_id bigint) RETURNS bigint
LANGUAGE sql STABLE
RETURN (SELECT coalesce(merged_into, customer_id) FROM customer
        WHERE customer_id = p_customer_id);

CREATE FUNCTION merge_customer(p_absorbed bigint, p_survivor bigint, p_reason text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_merge bigint;
    v_row record;
BEGIN
    -- Lock both rows in ID order: the absorbed one exclusively, the survivor
    -- only against key changes, so orders for the survivor keep flowing.
    FOR v_row IN SELECT customer_id FROM customer
                 WHERE customer_id IN (p_absorbed, p_survivor)
                 ORDER BY customer_id LOOP
        IF v_row.customer_id = p_absorbed THEN
            PERFORM FROM customer WHERE customer_id = p_absorbed FOR UPDATE;
        ELSE
            PERFORM FROM customer WHERE customer_id = p_survivor FOR NO KEY UPDATE;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM customer
        WHERE customer_id IN (p_absorbed, p_survivor) AND merged_into IS NULL) <> 2 THEN
        RAISE EXCEPTION 'customers % and % must be two different live customers',
            p_absorbed, p_survivor;
    END IF;

    INSERT INTO customer_merge (absorbed_id, survivor_id, reason)
    VALUES (p_absorbed, p_survivor, p_reason)
    RETURNING merge_id INTO v_merge;

    -- Addresses: the survivor's default wins; the absorbed default is demoted.
    WITH changed AS (
        UPDATE customer_address SET is_default = false
        WHERE customer_id = p_absorbed AND is_default
          AND EXISTS (SELECT FROM customer_address
                      WHERE customer_id = p_survivor AND is_default)
        RETURNING address_id)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key)
    SELECT v_merge, 'customer_address', 'demote', jsonb_build_object('address_id', address_id)
    FROM changed;
    WITH changed AS (
        UPDATE customer_address SET customer_id = p_survivor
        WHERE customer_id = p_absorbed
        RETURNING address_id)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key)
    SELECT v_merge, 'customer_address', 'repoint', jsonb_build_object('address_id', address_id)
    FROM changed;

    -- Teams: one membership per team; combine by keeping the earlier join date.
    WITH changed AS (
        UPDATE team_member AS s SET joined_on = a.joined_on
        FROM team_member AS a
        WHERE s.customer_id = p_survivor AND a.customer_id = p_absorbed
          AND a.team_id = s.team_id AND a.joined_on < s.joined_on
        RETURNING s.team_id, old.joined_on)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key, old_row)
    SELECT v_merge, 'team_member', 'adjust',
           jsonb_build_object('team_id', team_id, 'customer_id', p_survivor),
           jsonb_build_object('joined_on', joined_on)
    FROM changed;
    WITH changed AS (
        DELETE FROM team_member AS a
        USING team_member AS s
        WHERE a.customer_id = p_absorbed AND s.customer_id = p_survivor
          AND s.team_id = a.team_id
        RETURNING a.team_id, a.joined_on)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key, old_row)
    SELECT v_merge, 'team_member', 'drop',
           jsonb_build_object('team_id', team_id, 'customer_id', p_absorbed),
           jsonb_build_object('joined_on', joined_on)
    FROM changed;
    WITH changed AS (
        UPDATE team_member SET customer_id = p_survivor
        WHERE customer_id = p_absorbed
        RETURNING team_id)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key)
    SELECT v_merge, 'team_member', 'repoint',
           jsonb_build_object('team_id', team_id, 'customer_id', p_survivor)
    FROM changed;

    -- Orders and foreign IDs move without conflicts.
    WITH changed AS (
        UPDATE customer_order SET customer_id = p_survivor
        WHERE customer_id = p_absorbed
        RETURNING order_id)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key)
    SELECT v_merge, 'customer_order', 'repoint', jsonb_build_object('order_id', order_id)
    FROM changed;
    WITH changed AS (
        UPDATE customer_external_ref SET customer_id = p_survivor
        WHERE customer_id = p_absorbed
        RETURNING system, scope, external_id)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key)
    SELECT v_merge, 'customer_external_ref', 'repoint',
           jsonb_build_object('system', system, 'scope', scope, 'external_id', external_id)
    FROM changed;

    -- Rows absorbed earlier by p_absorbed now point at the new root.
    WITH changed AS (
        UPDATE customer SET merged_into = p_survivor
        WHERE merged_into = p_absorbed
        RETURNING customer_id)
    INSERT INTO customer_merge_change (merge_id, table_name, action, row_key)
    SELECT v_merge, 'customer', 'repoint', jsonb_build_object('customer_id', customer_id)
    FROM changed;

    -- The foreign keys reject this if any child still references p_absorbed.
    UPDATE customer SET merged_into = p_survivor, merged_at = now()
    WHERE customer_id = p_absorbed;
    RETURN v_merge;
END;
$$;

CREATE FUNCTION unmerge_customer(p_merge_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    m customer_merge;
BEGIN
    SELECT * INTO m FROM customer_merge WHERE merge_id = p_merge_id FOR UPDATE;
    IF m.merge_id IS NULL OR m.unmerged_at IS NOT NULL THEN
        RAISE EXCEPTION 'merge % does not exist or was already undone', p_merge_id;
    END IF;
    PERFORM FROM customer WHERE customer_id IN (m.absorbed_id, m.survivor_id)
    ORDER BY customer_id FOR UPDATE;
    IF EXISTS (SELECT FROM customer WHERE customer_id = m.survivor_id
               AND merged_into IS NOT NULL) THEN
        RAISE EXCEPTION 'survivor % was merged again; undo that merge first', m.survivor_id;
    END IF;

    UPDATE customer SET merged_into = NULL, merged_at = NULL
    WHERE customer_id = m.absorbed_id;

    -- Restore only rows that still point at the survivor.
    UPDATE customer AS c SET merged_into = m.absorbed_id
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'customer'
      AND c.customer_id = (j.row_key ->> 'customer_id')::bigint
      AND c.merged_into = m.survivor_id;
    UPDATE customer_order AS o SET customer_id = m.absorbed_id
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'customer_order'
      AND o.order_id = (j.row_key ->> 'order_id')::bigint
      AND o.customer_id = m.survivor_id;
    UPDATE customer_external_ref AS r SET customer_id = m.absorbed_id
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'customer_external_ref'
      AND (r.system, r.scope, r.external_id)
        = (j.row_key ->> 'system', j.row_key ->> 'scope', j.row_key ->> 'external_id')
      AND r.customer_id = m.survivor_id;
    UPDATE customer_address AS a SET customer_id = m.absorbed_id
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'customer_address'
      AND j.action = 'repoint'
      AND a.address_id = (j.row_key ->> 'address_id')::bigint
      AND a.customer_id = m.survivor_id;
    UPDATE customer_address AS a SET is_default = true
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'customer_address'
      AND j.action = 'demote'
      AND a.address_id = (j.row_key ->> 'address_id')::bigint
      AND a.customer_id = m.absorbed_id;
    UPDATE team_member AS t SET joined_on = (j.old_row ->> 'joined_on')::date
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'team_member'
      AND j.action = 'adjust'
      AND t.team_id = (j.row_key ->> 'team_id')::bigint
      AND t.customer_id = m.survivor_id;
    UPDATE team_member AS t SET customer_id = m.absorbed_id
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'team_member'
      AND j.action = 'repoint'
      AND t.team_id = (j.row_key ->> 'team_id')::bigint
      AND t.customer_id = m.survivor_id;
    INSERT INTO team_member (team_id, customer_id, joined_on)
    SELECT (j.row_key ->> 'team_id')::bigint, m.absorbed_id,
           (j.old_row ->> 'joined_on')::date
    FROM customer_merge_change AS j
    WHERE j.merge_id = p_merge_id AND j.table_name = 'team_member'
      AND j.action = 'drop'
    ON CONFLICT DO NOTHING;

    UPDATE customer_merge SET unmerged_at = now() WHERE merge_id = p_merge_id;
END;
$$;

INSERT INTO customer (public_id, display_name, email) VALUES
    ('cus_ann1', 'Ann Lee', 'ann@old.example'),     -- 1, survivor
    ('cus_ann2', 'Ann Lee', 'ann@new.example'),     -- 2, absorbed
    ('cus_bob', 'Bob Stone', 'bob@example.com'),    -- 3
    ('cus_eu', 'Northwind EU', NULL),               -- 4
    ('cus_us', 'Northwind US', NULL),               -- 5
    ('cus_ann3', 'A. Lee', NULL);                   -- 6, absorbed into 2 earlier
INSERT INTO customer_address VALUES
    (11, 1, DEFAULT, '1 Old Street', true),
    (21, 2, DEFAULT, '2 New Street', true),
    (22, 2, DEFAULT, '2 New Street, office', false),
    (61, 6, DEFAULT, '6 Side Street', true);
INSERT INTO team VALUES (10, 'Book club'), (20, 'Beta testers');
INSERT INTO team_member VALUES
    (10, 1, DEFAULT, DATE '2025-03-01'),
    (10, 2, DEFAULT, DATE '2024-06-01'),
    (20, 2, DEFAULT, DATE '2025-01-15');
INSERT INTO customer_order (order_id, customer_id) VALUES
    (100, 1), (101, 2), (102, 2), (103, 6), (400, 4), (500, 5);
INSERT INTO customer_external_ref (system, scope, external_id, customer_id) VALUES
    ('stripe', 'live', 'cus_NffrFeUfNV2Hib', 1),
    ('stripe', 'live', 'cus_Q8sZa', 2),
    ('crm', 'eu', '007', 2);

-- A merge into itself is rejected by the CHECK.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE customer SET merged_into = 3, merged_at = now() WHERE customer_id = 3;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Marking a row merged while children still reference it is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE customer SET merged_into = 1, merged_at = now() WHERE customer_id = 2;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- First merge: 6 into 2, leaving 2 as the survivor of an earlier merge.
SELECT merge_customer(6, 2, 'support ticket 4711') AS first_merge \gset
SELECT resolve_customer(6) = 2 AND (SELECT count(*) FROM customer_order WHERE customer_id = 2) = 3
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A merged row cannot become a survivor: merged_into must name a live row.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE customer SET merged_into = 6, merged_at = now() WHERE customer_id = 3;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Snapshot every child before the second merge, to compare after unmerge.
CREATE TEMP TABLE before_customer AS
    SELECT customer_id, merged_into FROM customer;
CREATE TEMP TABLE before_order AS SELECT order_id, customer_id FROM customer_order;
CREATE TEMP TABLE before_address AS
    SELECT address_id, customer_id, line, is_default FROM customer_address;
CREATE TEMP TABLE before_member AS SELECT team_id, customer_id, joined_on FROM team_member;
CREATE TEMP TABLE before_ref AS
    SELECT system, scope, external_id, customer_id FROM customer_external_ref;

-- Second merge: 2 into 1.
SELECT merge_customer(2, 1, 'same e-mail owner confirmed by phone') AS second_merge \gset

-- The old IDs resolve to the survivor; the chain 6 -> 2 was flattened to 6 -> 1.
SELECT resolve_customer(2) = 1 AND resolve_customer(6) = 1 AND resolve_customer(1) = 1
   AND (SELECT merged_into FROM customer WHERE customer_id = 6) = 1
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- All orders, addresses and foreign IDs moved; one default address remains.
SELECT (SELECT array_agg(order_id ORDER BY order_id) FROM customer_order
        WHERE customer_id = 1) = ARRAY[100, 101, 102, 103]::bigint[]
   AND (SELECT array_agg(address_id ORDER BY address_id) FROM customer_address
        WHERE customer_id = 1 AND is_default) = ARRAY[11]::bigint[]
   AND (SELECT count(*) FROM customer_address WHERE customer_id = 1) = 4
   AND (SELECT count(*) FROM customer_external_ref WHERE customer_id = 1) = 3
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Team 10 keeps one membership with the earlier join date; team 20 moved.
SELECT (SELECT array_agg(team_id || ':' || joined_on ORDER BY team_id) FROM team_member
        WHERE customer_id = 1) = ARRAY['10:2024-06-01', '20:2025-01-15']
   AND NOT EXISTS (SELECT FROM team_member WHERE customer_id IN (2, 6))
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The journal records what each step changed.
SELECT string_agg(table_name || '/' || action || '=' || n, ', '
                  ORDER BY table_name, action) AS journal
FROM (SELECT table_name, action, count(*) AS n FROM customer_merge_change
      WHERE merge_id = :second_merge GROUP BY 1, 2) AS s \gset
SELECT :'journal' = 'customer/repoint=1, customer_address/demote=1, customer_address/repoint=3, '
    'customer_external_ref/repoint=2, customer_order/repoint=3, team_member/adjust=1, '
    'team_member/drop=1, team_member/repoint=1' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A foreign ID of the absorbed row now finds the survivor.
SELECT (SELECT customer_id FROM customer_external_ref
        WHERE system = 'stripe' AND scope = 'live' AND external_id = 'cus_Q8sZa') = 1
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An old public ID is found and redirected to the survivor's public ID.
SELECT s.public_id = 'cus_ann1' AND c.merged_into IS NOT NULL AS valid
FROM customer AS c
JOIN customer AS s ON s.customer_id = coalesce(c.merged_into, c.customer_id)
WHERE c.public_id = 'cus_ann2' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A new order for the absorbed customer is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_order (order_id, customer_id) VALUES (104, 2);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Merging into an absorbed customer through the function is refused.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT merge_customer(3, 2, 'wrong target');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Copying the absorbed e-mail to the survivor is an ordinary update after the
-- merge; it is not journaled, so undoing the merge then collides on the e-mail.
SAVEPOINT email_choice;
UPDATE customer SET email = 'ann@new.example' WHERE customer_id = 1;
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT unmerge_customer(:second_merge);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
ROLLBACK TO SAVEPOINT email_choice;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- While the survivor is itself merged, the older merge cannot be undone.
SAVEPOINT later_merge;
SELECT merge_customer(1, 3, 'test of undo order') AS later_merge \gset
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT unmerge_customer(:second_merge);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
ROLLBACK TO SAVEPOINT later_merge;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- An order placed after the merge belongs to the survivor.
INSERT INTO customer_order (order_id, customer_id) VALUES (105, 1);
-- A moved order that support reassigned after the merge is not pulled back.
UPDATE customer_order SET customer_id = 3 WHERE order_id = 101;

-- Undo the second merge.
SELECT unmerge_customer(:second_merge) \gset ignored_

-- Every child row is back where it was; only the new order stays with 1.
SELECT NOT EXISTS (
         (SELECT customer_id, merged_into FROM customer EXCEPT SELECT * FROM before_customer)
         UNION ALL
         (SELECT * FROM before_customer EXCEPT SELECT customer_id, merged_into FROM customer))
   AND NOT EXISTS (
         (SELECT order_id, customer_id FROM customer_order WHERE order_id NOT IN (101, 105)
          EXCEPT SELECT * FROM before_order)
         UNION ALL
         (SELECT * FROM before_order WHERE order_id <> 101
          EXCEPT SELECT order_id, customer_id FROM customer_order))
   AND NOT EXISTS (
         (SELECT address_id, customer_id, line, is_default FROM customer_address
          EXCEPT SELECT * FROM before_address)
         UNION ALL
         (SELECT * FROM before_address
          EXCEPT SELECT address_id, customer_id, line, is_default FROM customer_address))
   AND NOT EXISTS (
         (SELECT team_id, customer_id, joined_on FROM team_member
          EXCEPT SELECT * FROM before_member)
         UNION ALL
         (SELECT * FROM before_member
          EXCEPT SELECT team_id, customer_id, joined_on FROM team_member))
   AND NOT EXISTS (
         (SELECT system, scope, external_id, customer_id FROM customer_external_ref
          EXCEPT SELECT * FROM before_ref)
         UNION ALL
         (SELECT * FROM before_ref
          EXCEPT SELECT system, scope, external_id, customer_id FROM customer_external_ref))
   AND (SELECT customer_id FROM customer_order WHERE order_id = 105) = 1
   AND (SELECT customer_id FROM customer_order WHERE order_id = 101) = 3
   AND resolve_customer(2) = 2 AND resolve_customer(6) = 2
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- The same merge cannot be undone twice.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
SELECT unmerge_customer(:second_merge);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = 'P0001' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Migration of a child with a plain key: the stored column rewrites the table,
-- then the composite key is added NOT VALID and validated separately.
CREATE TABLE legacy_invoice (
    invoice_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL
        CONSTRAINT legacy_invoice_customer_id_fkey REFERENCES customer (customer_id)
);
INSERT INTO legacy_invoice VALUES (900, 3);
SELECT pg_relation_filenode('legacy_invoice') AS node_before \gset
ALTER TABLE legacy_invoice
    ADD COLUMN customer_live boolean GENERATED ALWAYS AS (true) STORED;
SELECT pg_relation_filenode('legacy_invoice') <> :node_before AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- A plain column with a constant default and a CHECK is added without a rewrite.
CREATE TABLE legacy_note (
    note_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customer (customer_id)
);
INSERT INTO legacy_note VALUES (901, 3);
SELECT pg_relation_filenode('legacy_note') AS node_before \gset
ALTER TABLE legacy_note
    ADD COLUMN customer_live boolean NOT NULL DEFAULT true CHECK (customer_live);
SELECT pg_relation_filenode('legacy_note') = :node_before AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
ALTER TABLE legacy_invoice ADD CONSTRAINT legacy_invoice_customer_fkey
    FOREIGN KEY (customer_id, customer_live) REFERENCES customer (customer_id, is_live)
    NOT VALID;
ALTER TABLE legacy_invoice VALIDATE CONSTRAINT legacy_invoice_customer_fkey;
ALTER TABLE legacy_invoice DROP CONSTRAINT legacy_invoice_customer_id_fkey;
SELECT convalidated AS valid FROM pg_constraint
WHERE conname = 'legacy_invoice_customer_fkey' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Object Equivalence: link records as the same without moving anything.
CREATE TABLE equivalence_group (
    group_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reason text NOT NULL
);
CREATE TABLE customer_equivalence (
    customer_id bigint PRIMARY KEY REFERENCES customer (customer_id),
    group_id bigint NOT NULL REFERENCES equivalence_group (group_id)
);
CREATE INDEX customer_equivalence_group_idx ON customer_equivalence (group_id);
INSERT INTO equivalence_group (reason) VALUES ('Northwind subsidiaries, one account manager');
INSERT INTO customer_equivalence VALUES (4, 1), (5, 1);
SELECT (SELECT count(*) FROM customer_order AS o
        JOIN customer_equivalence AS e USING (customer_id)
        WHERE e.group_id = 1) = 2
   AND (SELECT customer_id FROM customer_order WHERE order_id = 500) = 5
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A customer belongs to at most one equivalence group.
INSERT INTO equivalence_group (reason) VALUES ('second guess');
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO customer_equivalence VALUES (5, 2);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;

-- Concurrency: two more sessions through dblink, on committed tables.
CREATE SCHEMA merge_race_example;
CREATE EXTENSION dblink SCHEMA merge_race_example;
SET search_path = merge_race_example, public;
CREATE TABLE customer (
    customer_id bigint PRIMARY KEY,
    merged_into bigint,
    is_live boolean GENERATED ALWAYS AS (merged_into IS NULL) STORED,
    target_live boolean
        GENERATED ALWAYS AS (CASE WHEN merged_into IS NOT NULL THEN true END) STORED,
    CONSTRAINT customer_live_key UNIQUE (customer_id, is_live),
    CONSTRAINT customer_merged_into_fkey FOREIGN KEY (merged_into, target_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE TABLE customer_order (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    customer_live boolean GENERATED ALWAYS AS (true) STORED,
    CONSTRAINT customer_order_customer_fkey FOREIGN KEY (customer_id, customer_live)
        REFERENCES customer (customer_id, is_live)
);
CREATE INDEX customer_order_customer_idx ON customer_order (customer_id);
-- The protocol from the main section, reduced to one child table.
CREATE FUNCTION merge_customer(p_absorbed bigint, p_survivor bigint)
RETURNS void LANGUAGE plpgsql SET search_path = merge_race_example AS $$
DECLARE
    v_id bigint;
BEGIN
    FOR v_id IN SELECT customer_id FROM customer
                WHERE customer_id IN (p_absorbed, p_survivor)
                ORDER BY customer_id LOOP
        IF v_id = p_absorbed THEN
            PERFORM FROM customer WHERE customer_id = v_id FOR UPDATE;
        ELSE
            PERFORM FROM customer WHERE customer_id = v_id FOR NO KEY UPDATE;
        END IF;
    END LOOP;
    UPDATE customer_order SET customer_id = p_survivor WHERE customer_id = p_absorbed;
    UPDATE customer SET merged_into = p_survivor WHERE customer_id = p_absorbed;
END;
$$;
INSERT INTO customer (customer_id) VALUES (1), (2), (3), (4), (5), (6), (7), (8);
SELECT dblink_connect('writer', 'dbname=' || current_database() || ' host=' || split_part(current_setting('unix_socket_directories'), ',', 1) || ' port=' || current_setting('port')) IS NOT NULL
   AND dblink_connect('merger', 'dbname=' || current_database() || ' host=' || split_part(current_setting('unix_socket_directories'), ',', 1) || ' port=' || current_setting('port')) IS NOT NULL
   AND dblink_exec('writer', 'SET lock_timeout = ''5s''') = 'SET'
   AND dblink_exec('merger', 'SET lock_timeout = ''5s''') = 'SET'
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 1. The merge locks first; an order for the absorbed customer waits, then fails.
SELECT dblink_exec('merger', 'BEGIN') = 'BEGIN'
   AND (SELECT r FROM dblink('merger',
        'SELECT merge_race_example.merge_customer(2, 1)::text') AS t (r text)) = ''
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- An order for the survivor does not wait: FOR NO KEY UPDATE allows FOR KEY SHARE.
SELECT dblink_exec('writer',
       'INSERT INTO merge_race_example.customer_order (order_id, customer_id) VALUES (10, 1)')
       = 'INSERT 0 1' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_send_query('writer',
       'INSERT INTO merge_race_example.customer_order (order_id, customer_id) VALUES (11, 2)') = 1
   AS sent \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'sent'::boolean AND dblink_is_busy('writer') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('merger', 'COMMIT') = 'COMMIT' AS valid \gset
-- dblink re-raises the remote error with its SQLSTATE.
\set ON_ERROR_STOP off
SELECT * FROM dblink_get_result('writer') AS r (status text);
\set race_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'valid'::boolean AND :'race_state' = '23503'
   AND dblink_error_message('writer') LIKE '%Key (customer_id, customer_live)=(2, t) is not present in table "customer"%'
   AS valid \gset
SELECT count(*) FROM dblink_get_result('writer', false) AS r (status text) \gset ignored_
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 2. The order comes first; the merge waits for it and then moves it.
SELECT dblink_exec('writer', 'BEGIN') = 'BEGIN'
   AND dblink_exec('writer',
       'INSERT INTO merge_race_example.customer_order (order_id, customer_id) VALUES (20, 4)')
       = 'INSERT 0 1'
   AS valid \gset
SELECT dblink_send_query('merger', 'SELECT merge_race_example.merge_customer(4, 3)') = 1
   AS sent \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'valid'::boolean AND :'sent'::boolean AND dblink_is_busy('merger') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('writer', 'COMMIT') = 'COMMIT' AS valid \gset
SELECT count(*) = 1 AS merged FROM dblink_get_result('merger') AS r (status text) \gset
SELECT count(*) FROM dblink_get_result('merger', false) AS r (status text) \gset ignored_
SELECT :'valid'::boolean AND :'merged'::boolean
   AND (SELECT customer_id FROM customer_order WHERE order_id = 20) = 3
   AND (SELECT merged_into FROM customer WHERE customer_id = 4) = 3
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 3. Without the explicit lock, the order slips past the re-pointing; marking
--    the row merged waits for the order (a key update) and then fails.
SELECT dblink_exec('writer', 'BEGIN') = 'BEGIN'
   AND dblink_exec('writer',
       'INSERT INTO merge_race_example.customer_order (order_id, customer_id) VALUES (30, 6)')
       = 'INSERT 0 1'
   AND dblink_exec('merger', 'BEGIN') = 'BEGIN'
   AND dblink_exec('merger',
       'UPDATE merge_race_example.customer_order SET customer_id = 5 WHERE customer_id = 6')
       = 'UPDATE 0'
   AS valid \gset
SELECT dblink_send_query('merger',
       'UPDATE merge_race_example.customer SET merged_into = 5 WHERE customer_id = 6') = 1
   AS sent \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'valid'::boolean AND :'sent'::boolean AND dblink_is_busy('merger') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('writer', 'COMMIT') = 'COMMIT' AS valid \gset
\set ON_ERROR_STOP off
SELECT * FROM dblink_get_result('merger') AS r (status text);
\set race_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'valid'::boolean AND :'race_state' = '23503'
   AND dblink_error_message('merger') LIKE '%Key (customer_id, is_live)=(6, t) is still referenced from table "customer_order"%'
   AS valid \gset
SELECT count(*) FROM dblink_get_result('merger', false) AS r (status text) \gset ignored_
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('merger', 'ROLLBACK') = 'ROLLBACK'
   AND (SELECT customer_id FROM customer_order WHERE order_id = 30) = 6
   AND (SELECT merged_into FROM customer WHERE customer_id = 6) IS NULL
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- 4. Order first again, but the merge runs at REPEATABLE READ.
SELECT dblink_exec('writer', 'BEGIN') = 'BEGIN'
   AND dblink_exec('writer',
       'INSERT INTO merge_race_example.customer_order (order_id, customer_id) VALUES (40, 8)')
       = 'INSERT 0 1'
   AND dblink_exec('merger', 'BEGIN ISOLATION LEVEL REPEATABLE READ') = 'BEGIN'
   AS valid \gset
SELECT dblink_send_query('merger', 'SELECT merge_race_example.merge_customer(8, 7)') = 1
   AS sent \gset
SELECT pg_sleep(0.3) AS slept \gset
SELECT :'valid'::boolean AND :'sent'::boolean AND dblink_is_busy('merger') = 1 AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('writer', 'COMMIT') = 'COMMIT' AS valid \gset
\set ON_ERROR_STOP off
SELECT * FROM dblink_get_result('merger') AS r (status text);
\set race_state :SQLSTATE
\set ON_ERROR_STOP on
-- The re-pointing used the transaction's older snapshot and missed the order;
-- the foreign key catches it when the row is marked merged.
SELECT :'valid'::boolean AND :'race_state' = '23503'
   AND dblink_error_message('merger') LIKE '%Key (customer_id, is_live)=(8, t) is still referenced from table "customer_order"%'
   AS valid \gset
SELECT count(*) FROM dblink_get_result('merger', false) AS r (status text) \gset ignored_
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT dblink_exec('merger', 'ROLLBACK') = 'ROLLBACK'
   AND (SELECT customer_id FROM customer_order WHERE order_id = 40) = 8
   AND (SELECT merged_into FROM customer WHERE customer_id = 8) IS NULL
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

SELECT dblink_disconnect('writer') = 'OK' AND dblink_disconnect('merger') = 'OK' AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
RESET search_path;
DROP SCHEMA merge_race_example CASCADE;
