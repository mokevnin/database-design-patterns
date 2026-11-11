-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f localized-values.sql in an empty database.
-- Expected errors are intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on

CREATE TABLE app_locale (
    locale text COLLATE "C" PRIMARY KEY,
    CHECK (locale = lower(locale))
);
CREATE TABLE product (
    product_id bigint PRIMARY KEY,
    sku text NOT NULL UNIQUE,
    default_locale text COLLATE "C" NOT NULL REFERENCES app_locale (locale)
);
CREATE TABLE product_text (
    product_id bigint NOT NULL REFERENCES product (product_id)
        ON DELETE CASCADE,
    locale text COLLATE "C" NOT NULL REFERENCES app_locale (locale),
    name text NOT NULL CHECK (btrim(name) <> ''),
    CONSTRAINT product_text_pkey PRIMARY KEY (product_id, locale)
);
ALTER TABLE product ADD CONSTRAINT product_default_text_fk
    FOREIGN KEY (product_id, default_locale)
    REFERENCES product_text (product_id, locale)
    DEFERRABLE INITIALLY DEFERRED;
INSERT INTO app_locale VALUES ('en'), ('fr'), ('fr-ca');
BEGIN;
INSERT INTO product VALUES (1, 'CHAIR', 'en'), (2, 'DESK', 'en');
INSERT INTO product_text VALUES
    (1, 'en', 'Chair'), (1, 'fr', 'Chaise'), (2, 'en', 'Desk');
COMMIT;
SELECT p.sku, chosen.locale, chosen.name
FROM product AS p
CROSS JOIN LATERAL (
    SELECT t.locale, t.name
    FROM (VALUES ('fr-ca', 1), ('fr', 2), (p.default_locale, 3))
        AS preference(locale, priority)
    JOIN product_text AS t
      ON t.product_id = p.product_id AND t.locale = preference.locale
    ORDER BY preference.priority
    LIMIT 1
) AS chosen
ORDER BY p.product_id;
UPDATE product_text SET name = 'Chaise en bois'
WHERE product_id = 1 AND locale = 'fr';

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
INSERT INTO product_text VALUES (1, 'fr', 'Autre chaise');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
BEGIN;
INSERT INTO product VALUES (3, 'LAMP', 'en');
COMMIT;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM product WHERE product_id = 3);
END $$;

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
DELETE FROM product_text WHERE product_id = 1 AND locale = 'en';
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

-- This rejection is intentional; verify it and continue.
\set ON_ERROR_STOP off
INSERT INTO product_text VALUES (1, 'fr-ca', '   ');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
CREATE INDEX product_text_en_search_idx ON product_text
    USING gin (to_tsvector('english'::regconfig, name)) WHERE locale = 'en';
SELECT product_id FROM product_text
WHERE locale = 'en'
  AND to_tsvector('english'::regconfig, name)
      @@ plainto_tsquery('english'::regconfig, 'chairs')
ORDER BY product_id;
SELECT product_id, name FROM product_text
WHERE locale = 'en' ORDER BY name COLLATE "C", product_id;

DO $$ BEGIN
    ASSERT (SELECT array_agg(product_id ORDER BY product_id) = ARRAY[1]::bigint[] FROM product_text WHERE locale = 'en' AND to_tsvector('english'::regconfig, name) @@ plainto_tsquery('english'::regconfig, 'chairs'));
END $$;

-- Switch default and remove the previous default atomically.
BEGIN;
UPDATE product SET default_locale = 'fr' WHERE product_id = 1;
DELETE FROM product_text WHERE product_id = 1 AND locale = 'en';
COMMIT;
DELETE FROM product WHERE product_id = 1;

DO $$ BEGIN
    ASSERT (SELECT count(*) = 0 FROM product_text WHERE product_id = 1);
END $$;
