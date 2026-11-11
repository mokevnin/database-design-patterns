-- Checked on PostgreSQL 18.6. Run with psql -X -v ON_ERROR_STOP=1 -f this-file.sql.
BEGIN;
CREATE SCHEMA json_lab;
SET LOCAL search_path = json_lab, public;

CREATE TABLE device_model (model_id bigint PRIMARY KEY, name text NOT NULL UNIQUE);
CREATE TABLE device (
    device_id bigint PRIMARY KEY,
    serial_number text NOT NULL UNIQUE,
    model_id bigint NOT NULL REFERENCES device_model (model_id),
    settings jsonb NOT NULL DEFAULT '{}',
    version bigint NOT NULL DEFAULT 1,
    brightness numeric GENERATED ALWAYS AS (
        CASE WHEN jsonb_typeof(settings -> 'brightness') = 'number'
            THEN (settings ->> 'brightness')::numeric END
    ) STORED,
    CONSTRAINT device_settings_object CHECK (jsonb_typeof(settings) = 'object'),
    CONSTRAINT device_brightness CHECK (
        CASE WHEN settings ? 'brightness' THEN
            jsonb_typeof(settings -> 'brightness') = 'number'
            AND brightness BETWEEN 0 AND 100
        ELSE true END
    )
);
CREATE INDEX device_model_idx ON device (model_id);
CREATE INDEX device_settings_idx ON device USING gin (settings jsonb_path_ops);
CREATE INDEX device_brightness_idx ON device (brightness);

INSERT INTO device_model VALUES (10, 'Lamp');
INSERT INTO device (device_id, serial_number, model_id, settings)
VALUES (1, 'D-1', 10, '{"brightness":40,"color":"warm"}'), (2, 'D-2', 10, '{}');
SELECT device_id FROM device WHERE settings @> '{"color":"warm"}';
SELECT device_id, brightness FROM device WHERE brightness BETWEEN 30 AND 50;
UPDATE device
SET settings = jsonb_set(settings, '{brightness}', '60'::jsonb), version = version + 1
WHERE device_id = 1 AND version = 1;
SELECT brightness, version FROM device WHERE device_id = 1;
-- A stale whole-document replacement must affect zero rows.
UPDATE device SET settings = '{"color":"cool"}', version = version + 1
WHERE device_id = 1 AND version = 1;
DO $$
BEGIN
    BEGIN
        INSERT INTO device (device_id, serial_number, model_id, settings)
        VALUES (3, 'D-3', 10, '{"brightness":"60"}');
        RAISE EXCEPTION 'Expected string-instead-of-number rejection';
    EXCEPTION WHEN check_violation THEN
        IF SQLERRM <> 'new row for relation "device" violates check constraint "device_brightness"' THEN
            RAISE;
        END IF;
        RAISE NOTICE 'Expected SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO device (device_id, serial_number, model_id, settings)
        VALUES (4, 'D-4', 10, '{"brightness":null}');
        RAISE EXCEPTION 'Expected JSON-null rejection';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'Expected JSON-null SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
    BEGIN
        INSERT INTO device (device_id, serial_number, model_id, settings)
        VALUES (5, 'D-5', 10, '{"brightness":101}');
        RAISE EXCEPTION 'Expected out-of-range rejection';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'Expected range SQLSTATE %: %', SQLSTATE, SQLERRM;
    END;
END $$;
ROLLBACK;
