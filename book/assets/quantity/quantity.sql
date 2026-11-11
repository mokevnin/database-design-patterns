-- Checked on PostgreSQL 18.6 (Homebrew).
-- Multiplicative units only. Currency conversion is deliberately excluded.
\set ON_ERROR_STOP on
CREATE SCHEMA quantity_example;
SET search_path = quantity_example, public;

CREATE TABLE unit (
    unit_code text PRIMARY KEY,
    dimension text NOT NULL,
    to_base numeric NOT NULL CHECK (to_base > 0 AND to_base < 'Infinity'::numeric),
    UNIQUE (unit_code, dimension)
);
CREATE TABLE measured_amount (
    amount_id bigint PRIMARY KEY,
    dimension text NOT NULL,
    amount numeric NOT NULL CHECK (amount > '-Infinity'::numeric AND amount < 'Infinity'::numeric),
    unit_code text NOT NULL,
    CONSTRAINT amount_unit_dimension_fk FOREIGN KEY (unit_code, dimension)
        REFERENCES unit (unit_code, dimension)
);
CREATE FUNCTION convert_amount(value numeric, source_unit text, target_unit text)
RETURNS numeric LANGUAGE plpgsql STABLE STRICT SET search_path = quantity_example, pg_temp AS $$
DECLARE
    source unit%ROWTYPE;
    target unit%ROWTYPE;
BEGIN
    SELECT * INTO STRICT source FROM unit WHERE unit_code = source_unit;
    SELECT * INTO STRICT target FROM unit WHERE unit_code = target_unit;
    IF source.dimension <> target.dimension THEN
        RAISE EXCEPTION 'incompatible quantity dimensions' USING ERRCODE = '22023';
    END IF;
    IF NOT (value > '-Infinity'::numeric AND value < 'Infinity'::numeric) THEN
        RAISE EXCEPTION 'quantity must be finite' USING ERRCODE = '22023';
    END IF;
    RETURN value * source.to_base / target.to_base;
END $$;
CREATE FUNCTION add_quantities(left_value numeric, left_unit text, right_value numeric, right_unit text)
RETURNS numeric LANGUAGE sql STABLE STRICT SET search_path = quantity_example, pg_temp AS $$
    SELECT convert_amount(left_value, left_unit, left_unit)
           + convert_amount(right_value, right_unit, left_unit)
$$;

INSERT INTO unit VALUES
    ('kg', 'mass', 1), ('g', 'mass', 0.001),
    ('L', 'volume', 1), ('mL', 'volume', 0.001),
    ('EUR', 'currency:EUR', 1), ('USD', 'currency:USD', 1);
INSERT INTO measured_amount VALUES (1, 'mass', 2, 'kg'), (2, 'mass', 500, 'g');
SELECT round(add_quantities(2, 'kg', 500, 'g'), 3) AS kilograms;
SELECT a.dimension, sum(a.amount * u.to_base) AS base_amount
FROM measured_amount AS a JOIN unit AS u USING (unit_code, dimension)
GROUP BY a.dimension;
UPDATE measured_amount SET amount = 750 WHERE amount_id = 2;
SELECT round(convert_amount(amount, unit_code, 'kg'), 3)
FROM measured_amount WHERE amount_id = 2;
SELECT round(1.005::numeric, 2), round(-1.005::numeric, 2);

DO $$
BEGIN
    BEGIN
        INSERT INTO measured_amount VALUES (3, 'mass', 2, 'L');
        RAISE EXCEPTION 'expected dimension mismatch';
    EXCEPTION WHEN foreign_key_violation THEN
        IF SQLERRM NOT LIKE '%amount_unit_dimension_fk%' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        PERFORM add_quantities(2, 'kg', 1, 'L');
        RAISE EXCEPTION 'expected incompatible addition';
    EXCEPTION WHEN invalid_parameter_value THEN
        IF SQLERRM <> 'incompatible quantity dimensions' THEN RAISE; END IF;
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        PERFORM convert_amount(10, 'EUR', 'USD');
        RAISE EXCEPTION 'expected currency conversion refusal';
    EXCEPTION WHEN invalid_parameter_value THEN
        RAISE NOTICE 'expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    ASSERT add_quantities(2, 'kg', 500, 'g') = 2.5;
    ASSERT (SELECT sum(a.amount * u.to_base)
            FROM measured_amount AS a JOIN unit AS u USING (unit_code, dimension)) = 2.75;
END $$;
