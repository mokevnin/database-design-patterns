-- Checked on PostgreSQL 18.6 (Homebrew). Run with psql -X -f untyped-properties.sql.
-- Isolated lab schema; run once in a disposable database. Expected errors are asserted.
\set ON_ERROR_STOP on
CREATE SCHEMA untyped_properties_lab;
SET search_path TO untyped_properties_lab, public;

CREATE OR REPLACE FUNCTION pg_temp.expect_error(command text, expected_state text, expected_message text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    actual_state text;
    actual_message text;
BEGIN
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE,
            actual_message = MESSAGE_TEXT;
    END;
    IF actual_state IS DISTINCT FROM expected_state
       OR actual_message IS DISTINCT FROM expected_message THEN
        RAISE EXCEPTION 'Expected %: %, got %: %', expected_state,
            expected_message, actual_state, actual_message;
    END IF;
    RAISE NOTICE 'Expected %: %', actual_state, actual_message;
END;
$$;

CREATE TABLE product (product_id bigint PRIMARY KEY, name text NOT NULL);
CREATE TABLE property_old (
    product_id bigint NOT NULL REFERENCES product (product_id),
    property_name text NOT NULL,
    value text COLLATE "C" NOT NULL,
    PRIMARY KEY (product_id, property_name)
);
INSERT INTO product VALUES (1, 'Crate'), (2, 'Box'), (3, 'Bag'), (4, 'Envelope');
INSERT INTO property_old VALUES
    (1, 'weight_kg', '100'), (1, 'color', 'red'),
    (2, 'weight_kg', '2'), (2, 'color', 'red'),
    (3, 'weight_kg', 'heavy'), (3, 'color', 'blue'), (4, 'color', 'green');
SELECT product_id FROM property_old
WHERE property_name = 'weight_kg' AND value < '20' ORDER BY product_id;

CREATE TABLE product_spec (
    product_id bigint PRIMARY KEY REFERENCES product (product_id),
    weight_kg numeric NOT NULL,
    color text NOT NULL,
    CONSTRAINT product_spec_weight CHECK (weight_kg > 0 AND weight_kg < 'Infinity'::numeric)
);
CREATE INDEX product_spec_weight_color_idx ON product_spec (weight_kg, color);
CREATE TABLE property_reject (
    product_id bigint PRIMARY KEY REFERENCES product (product_id),
    reason text NOT NULL
);
BEGIN;
LOCK TABLE product, property_old IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE parsed_spec ON COMMIT DROP AS
SELECT p.product_id, c.value AS color,
       CASE WHEN pg_input_is_valid(w.value, 'numeric') THEN w.value::numeric END AS weight_kg
FROM product AS p
LEFT JOIN property_old AS w ON w.product_id = p.product_id AND w.property_name = 'weight_kg'
LEFT JOIN property_old AS c ON c.product_id = p.product_id AND c.property_name = 'color';
INSERT INTO product_spec
SELECT product_id, weight_kg, color FROM parsed_spec
WHERE color IS NOT NULL AND weight_kg > 0 AND weight_kg < 'Infinity'::numeric;
INSERT INTO property_reject
SELECT product_id, 'missing or invalid required field' FROM parsed_spec AS p
WHERE NOT EXISTS (SELECT 1 FROM product_spec AS s WHERE s.product_id = p.product_id);
COMMIT;
SELECT product_id FROM product_spec WHERE weight_kg < 20 AND color = 'red';
SELECT * FROM property_reject ORDER BY product_id;

SELECT pg_temp.expect_error($operation$INSERT INTO product_spec VALUES (3, 'heavy', 'blue');$operation$, '22P02', 'invalid input syntax for type numeric: "heavy"');

SELECT pg_temp.expect_error($operation$INSERT INTO product_spec (product_id, color) VALUES (4, 'green');$operation$, '23502', 'null value in column "weight_kg" of relation "product_spec" violates not-null constraint');

DO $$ BEGIN
    ASSERT (SELECT count(*) = 2 FROM product_spec);
    ASSERT (SELECT count(*) = 2 FROM property_reject);
END $$;
