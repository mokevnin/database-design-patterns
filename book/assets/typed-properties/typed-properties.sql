-- Checked on PostgreSQL 18.6. Run with psql -X -v ON_ERROR_STOP=1 -f this-file.sql.
-- Use read committed; value mutations lock their product before checking completeness.
BEGIN;
CREATE SCHEMA property_lab;
SET LOCAL search_path = property_lab, public;

CREATE TABLE property_profile (
    profile_id bigint PRIMARY KEY,
    state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'published')),
    UNIQUE (profile_id, state)
);
CREATE TABLE property_definition (
    profile_id bigint NOT NULL REFERENCES property_profile (profile_id),
    property_key text NOT NULL,
    value_kind text NOT NULL CHECK (value_kind IN ('number', 'text')),
    required boolean NOT NULL DEFAULT false,
    minimum numeric,
    maximum numeric,
    PRIMARY KEY (profile_id, property_key),
    UNIQUE (profile_id, property_key, value_kind),
    CHECK (
        (value_kind = 'number' AND minimum IS NOT NULL AND maximum IS NOT NULL
            AND minimum <= maximum AND minimum > '-Infinity'::numeric
            AND maximum < 'Infinity'::numeric)
        OR (value_kind = 'text' AND minimum IS NULL AND maximum IS NULL)
    )
);
CREATE TABLE product (
    product_id bigint PRIMARY KEY,
    profile_id bigint NOT NULL,
    profile_state text NOT NULL DEFAULT 'published' CHECK (profile_state = 'published'),
    state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'active')),
    UNIQUE (product_id, profile_id),
    FOREIGN KEY (profile_id, profile_state) REFERENCES property_profile (profile_id, state)
);
CREATE TABLE property_value (
    product_id bigint NOT NULL,
    profile_id bigint NOT NULL,
    property_key text NOT NULL,
    value_kind text NOT NULL,
    number_value numeric,
    text_value text,
    PRIMARY KEY (product_id, property_key),
    FOREIGN KEY (product_id, profile_id) REFERENCES product (product_id, profile_id)
        ON DELETE CASCADE,
    FOREIGN KEY (profile_id, property_key, value_kind)
        REFERENCES property_definition (profile_id, property_key, value_kind),
    CONSTRAINT property_value_shape CHECK (
        (value_kind = 'number' AND number_value IS NOT NULL AND text_value IS NULL)
        OR (value_kind = 'text' AND number_value IS NULL AND text_value IS NOT NULL)
    )
);
CREATE INDEX property_value_number_idx
    ON property_value (profile_id, property_key, number_value, product_id)
    WHERE value_kind = 'number';
CREATE INDEX property_value_text_idx
    ON property_value (profile_id, property_key, text_value, product_id)
    WHERE value_kind = 'text';

CREATE FUNCTION guard_published_profile() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.state = 'published' THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'published profile is immutable';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER profile_immutable BEFORE UPDATE ON property_profile
    FOR EACH ROW EXECUTE FUNCTION guard_published_profile();

CREATE FUNCTION guard_definition() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    target_profile bigint;
    profile_status text;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.profile_id <> OLD.profile_id THEN
        RAISE EXCEPTION 'create a new definition instead of moving it';
    END IF;
    target_profile := CASE WHEN TG_OP = 'DELETE' THEN OLD.profile_id ELSE NEW.profile_id END;
    SELECT state INTO profile_status FROM property_profile
    WHERE profile_id = target_profile FOR UPDATE;
    IF profile_status = 'published' THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'published definitions are immutable';
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER definition_guard BEFORE INSERT OR UPDATE OR DELETE ON property_definition
    FOR EACH ROW EXECUTE FUNCTION guard_definition();

CREATE FUNCTION guard_property_value() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    target_product bigint;
    definition property_definition%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.product_id <> OLD.product_id THEN
        RAISE EXCEPTION 'delete and insert instead of moving a value';
    END IF;
    target_product := CASE WHEN TG_OP = 'DELETE' THEN OLD.product_id ELSE NEW.product_id END;
    PERFORM 1 FROM product WHERE product_id = target_product FOR UPDATE;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    SELECT * INTO definition FROM property_definition
    WHERE profile_id = NEW.profile_id AND property_key = NEW.property_key;
    IF NEW.value_kind = 'number' AND NOT
        (NEW.number_value BETWEEN definition.minimum AND definition.maximum) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'property value outside allowed range';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER value_guard BEFORE INSERT OR UPDATE OR DELETE ON property_value
    FOR EACH ROW EXECUTE FUNCTION guard_property_value();

CREATE FUNCTION check_required_properties() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    target_product bigint;
BEGIN
    target_product := CASE WHEN TG_OP = 'DELETE' THEN OLD.product_id ELSE NEW.product_id END;
    IF EXISTS (
        SELECT 1 FROM product AS p
        JOIN property_definition AS d ON d.profile_id = p.profile_id
        WHERE p.product_id = target_product AND p.state = 'active' AND d.required
          AND NOT EXISTS (
              SELECT 1 FROM property_value AS v
              WHERE v.product_id = p.product_id AND v.property_key = d.property_key
          )
    ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'active product lacks required property';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER product_complete AFTER INSERT OR UPDATE ON product
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_required_properties();
CREATE CONSTRAINT TRIGGER value_complete AFTER INSERT OR UPDATE OR DELETE ON property_value
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_required_properties();

INSERT INTO property_profile (profile_id) VALUES (1);
INSERT INTO property_definition VALUES
    (1, 'weight_kg', 'number', true, 0.01, 1000),
    (1, 'color', 'text', false, NULL, NULL);
UPDATE property_profile SET state = 'published' WHERE profile_id = 1;
INSERT INTO product (product_id, profile_id) VALUES (10, 1);
INSERT INTO property_value VALUES
    (10, 1, 'weight_kg', 'number', 2.5, NULL),
    (10, 1, 'color', 'text', NULL, 'red');
UPDATE product SET state = 'active' WHERE product_id = 10;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT p.product_id FROM product AS p
JOIN property_value AS w ON w.product_id = p.product_id
    AND w.profile_id = p.profile_id AND w.property_key = 'weight_kg'
JOIN property_value AS c ON c.product_id = p.product_id
    AND c.profile_id = p.profile_id AND c.property_key = 'color'
WHERE p.profile_id = 1 AND p.state = 'active'
  AND w.value_kind = 'number' AND w.number_value < 5
  AND c.value_kind = 'text' AND c.text_value = 'red';
UPDATE property_value SET number_value = 3 WHERE product_id = 10 AND property_key = 'weight_kg';
DO $$
BEGIN
    BEGIN
        UPDATE property_value SET number_value = 2000
        WHERE product_id = 10 AND property_key = 'weight_kg';
        RAISE EXCEPTION 'Expected range rejection';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'property value outside allowed range' THEN RAISE; END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        DELETE FROM property_value WHERE product_id = 10 AND property_key = 'weight_kg';
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Expected required property rejection';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'active product lacks required property' THEN RAISE; END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO product (product_id, profile_id, state) VALUES (11, 1, 'active');
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Expected incomplete activation rejection';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'Expected activation SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        UPDATE property_definition SET maximum = 2 WHERE profile_id = 1 AND property_key = 'weight_kg';
        RAISE EXCEPTION 'Expected definition mutation rejection';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'Expected metadata SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        UPDATE property_value SET value_kind = 'text', number_value = NULL, text_value = 'heavy'
        WHERE product_id = 10 AND property_key = 'weight_kg';
        RAISE EXCEPTION 'Expected type mismatch rejection';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Expected type SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
-- Definitions evolve by publishing another complete profile, then migrating a product.
INSERT INTO property_profile (profile_id) VALUES (2);
INSERT INTO property_definition VALUES
    (2, 'weight_kg', 'number', true, 0.01, 500),
    (2, 'color', 'text', false, NULL, NULL);
UPDATE property_profile SET state = 'published' WHERE profile_id = 2;
DELETE FROM property_value WHERE product_id = 10;
UPDATE product SET profile_id = 2 WHERE product_id = 10;
INSERT INTO property_value VALUES
    (10, 2, 'weight_kg', 'number', 3, NULL),
    (10, 2, 'color', 'text', NULL, 'red');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT product_id, profile_id, state FROM product;
DELETE FROM product WHERE product_id = 10;
SELECT count(*) AS remaining_values FROM property_value;
ROLLBACK;
