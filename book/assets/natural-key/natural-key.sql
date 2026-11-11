-- Checked on PostgreSQL 18.6.
-- Run with psql -X -f natural-key.sql in an empty database.
-- The duplicate-line error is intentional and checked by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE sales_order (
    order_number text PRIMARY KEY,
    buyer_name text NOT NULL
);
CREATE TABLE order_line (
    order_number text NOT NULL REFERENCES sales_order (order_number)
        ON UPDATE CASCADE,
    line_number integer NOT NULL CHECK (line_number > 0),
    product_code text NOT NULL,
    quantity integer NOT NULL CHECK (quantity > 0),
    CONSTRAINT order_line_pkey PRIMARY KEY (order_number, line_number)
);
CREATE TABLE line_note (
    order_number text NOT NULL,
    line_number integer NOT NULL,
    note text NOT NULL,
    PRIMARY KEY (order_number, line_number),
    FOREIGN KEY (order_number, line_number)
        REFERENCES order_line (order_number, line_number) ON UPDATE CASCADE
);

INSERT INTO sales_order VALUES ('SO-104', 'Northwind');
INSERT INTO order_line VALUES ('SO-104', 1, 'PEN', 2);
INSERT INTO line_note VALUES ('SO-104', 1, 'Gift wrap');
SELECT product_code, quantity FROM order_line
WHERE order_number = 'SO-104' AND line_number = 1;
UPDATE sales_order SET order_number = 'SO-204'
WHERE order_number = 'SO-104';
SELECT order_number, line_number, note FROM line_note;
-- order_number = SO-204, line_number = 1, note = Gift wrap.

SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO order_line VALUES ('SO-204', 1, 'PENCIL', 1);
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif

ROLLBACK;
