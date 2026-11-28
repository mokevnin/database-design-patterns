-- Checked on PostgreSQL 18.7.
-- Run with psql -X -f proposed-change.sql in an empty disposable database.
-- Expected errors are displayed and asserted by SQLSTATE.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA proposal_example;

CREATE TABLE proposal_example.app_user (
    user_id bigint PRIMARY KEY,
    name text NOT NULL
);
INSERT INTO proposal_example.app_user VALUES (1, 'alice'), (2, 'bob'), (3, 'carol');

------------------------------------------------------------------------------
-- Shape 1: a published row and a draft of the same object side by side.
------------------------------------------------------------------------------
CREATE TABLE proposal_example.page (
    page_id bigint PRIMARY KEY,
    title text NOT NULL,
    body text NOT NULL,
    version bigint NOT NULL DEFAULT 0
);
CREATE TABLE proposal_example.page_draft (
    page_id bigint PRIMARY KEY REFERENCES proposal_example.page (page_id),
    title text NOT NULL,
    body text NOT NULL,
    base_version bigint NOT NULL,
    draft_revision bigint NOT NULL DEFAULT 1,
    edited_by bigint NOT NULL REFERENCES proposal_example.app_user (user_id)
);

INSERT INTO proposal_example.page VALUES (1, 'Pricing', 'Old prices', 0);

-- An editor starts a draft from the published version 0 and saves it twice.
INSERT INTO proposal_example.page_draft (page_id, title, body, base_version, edited_by)
SELECT page_id, title, 'New prices', version, 1
FROM proposal_example.page WHERE page_id = 1;
UPDATE proposal_example.page_draft
SET body = 'New prices, final', draft_revision = draft_revision + 1
WHERE page_id = 1 AND draft_revision = 1;

-- Readers still see the published row.
SELECT (SELECT body = 'Old prices' FROM proposal_example.page WHERE page_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A reviewer approved draft revision 1; the draft has moved on, so publishing it does nothing.
WITH draft AS (
    SELECT page_id, title, body, base_version
    FROM proposal_example.page_draft
    WHERE page_id = 1 AND draft_revision = 1
    FOR UPDATE
), published AS (
    UPDATE proposal_example.page p
    SET title = draft.title, body = draft.body, version = p.version + 1
    FROM draft
    WHERE p.page_id = draft.page_id AND p.version = draft.base_version
    RETURNING p.page_id, p.version
), removed AS (
    DELETE FROM proposal_example.page_draft d
    USING published WHERE d.page_id = published.page_id
    RETURNING published.version
)
SELECT count(*) = 0 AS valid FROM removed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Publishing the reviewed revision 2 copies it over the published row and removes the draft.
WITH draft AS (
    SELECT page_id, title, body, base_version
    FROM proposal_example.page_draft
    WHERE page_id = 1 AND draft_revision = 2
    FOR UPDATE
), published AS (
    UPDATE proposal_example.page p
    SET title = draft.title, body = draft.body, version = p.version + 1
    FROM draft
    WHERE p.page_id = draft.page_id AND p.version = draft.base_version
    RETURNING p.page_id, p.version
), removed AS (
    DELETE FROM proposal_example.page_draft d
    USING published WHERE d.page_id = published.page_id
    RETURNING published.version
)
SELECT version = 1 AS valid FROM removed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT (SELECT body = 'New prices, final' AND version = 1
        FROM proposal_example.page WHERE page_id = 1)
   AND NOT EXISTS (SELECT FROM proposal_example.page_draft WHERE page_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A new draft starts from version 1, then a hotfix changes the published row directly.
INSERT INTO proposal_example.page_draft (page_id, title, body, base_version, edited_by)
SELECT page_id, title, 'Prices for 2027', version, 1
FROM proposal_example.page WHERE page_id = 1;
UPDATE proposal_example.page
SET body = 'New prices, typo fixed', version = version + 1
WHERE page_id = 1 AND version = 1;

-- Publishing the draft now finds version 2, not its base 1: nothing changes and the draft stays.
WITH draft AS (
    SELECT page_id, title, body, base_version
    FROM proposal_example.page_draft
    WHERE page_id = 1 AND draft_revision = 1
    FOR UPDATE
), published AS (
    UPDATE proposal_example.page p
    SET title = draft.title, body = draft.body, version = p.version + 1
    FROM draft
    WHERE p.page_id = draft.page_id AND p.version = draft.base_version
    RETURNING p.page_id, p.version
), removed AS (
    DELETE FROM proposal_example.page_draft d
    USING published WHERE d.page_id = published.page_id
    RETURNING published.version
)
SELECT count(*) = 0 AS valid FROM removed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT (SELECT body = 'New prices, typo fixed' FROM proposal_example.page WHERE page_id = 1)
   AND EXISTS (SELECT FROM proposal_example.page_draft WHERE page_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

------------------------------------------------------------------------------
-- Shape 2: pending change rows, decided by a second person and applied later.
------------------------------------------------------------------------------
CREATE TABLE proposal_example.product (
    product_id bigint PRIMARY KEY,
    name text NOT NULL,
    price numeric(12, 2) NOT NULL CHECK (price > 0),
    version bigint NOT NULL DEFAULT 0
);
CREATE TABLE proposal_example.price_change (
    change_id bigint PRIMARY KEY,
    product_id bigint NOT NULL REFERENCES proposal_example.product (product_id),
    proposed_price numeric(12, 2) NOT NULL CHECK (proposed_price > 0),
    base_version bigint NOT NULL,
    requested_by bigint NOT NULL REFERENCES proposal_example.app_user (user_id),
    requested_at timestamptz NOT NULL DEFAULT now(),
    state text NOT NULL DEFAULT 'proposed',
    closed_at timestamptz,
    CONSTRAINT price_change_state_known CHECK
        (state IN ('proposed', 'approved', 'rejected', 'withdrawn', 'applied', 'stale')),
    CONSTRAINT price_change_closed_when_final CHECK
        ((state IN ('proposed', 'approved')) = (closed_at IS NULL)),
    CONSTRAINT price_change_requester_key UNIQUE (change_id, requested_by)
);
CREATE TABLE proposal_example.price_change_decision (
    change_id bigint PRIMARY KEY,
    requested_by bigint NOT NULL,
    decided_by bigint NOT NULL REFERENCES proposal_example.app_user (user_id),
    verdict text NOT NULL CHECK (verdict IN ('approve', 'reject')),
    decided_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT price_change_decision_proposal_fkey FOREIGN KEY (change_id, requested_by)
        REFERENCES proposal_example.price_change (change_id, requested_by),
    CONSTRAINT price_change_decision_four_eyes CHECK (decided_by <> requested_by)
);

INSERT INTO proposal_example.product VALUES (1, 'Espresso machine', 100.00, 0);

-- Alice and Bob each propose a price, both based on the version 0 they saw.
INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 1, product_id, 120.00, version, 1 FROM proposal_example.product
WHERE product_id = 1 AND version = 0;
INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 2, product_id, 110.00, version, 2 FROM proposal_example.product
WHERE product_id = 1 AND version = 0;

-- Alice cannot approve her own proposal.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
WITH moved AS (
    UPDATE proposal_example.price_change SET state = 'approved'
    WHERE change_id = 1 AND state = 'proposed'
    RETURNING change_id, requested_by
)
INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
SELECT change_id, requested_by, 1, 'approve' FROM moved;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
-- The failed statement left the proposal open.
SELECT (SELECT state = 'proposed' FROM proposal_example.price_change WHERE change_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Nor can she evade the check by naming someone else as the requester.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
VALUES (1, 2, 1, 'approve');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Bob approves Alice's proposal; Carol approves Bob's. Both decisions succeed.
WITH moved AS (
    UPDATE proposal_example.price_change SET state = 'approved'
    WHERE change_id = 1 AND state = 'proposed'
    RETURNING change_id, requested_by
)
INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
SELECT change_id, requested_by, 2, 'approve' FROM moved;
WITH moved AS (
    UPDATE proposal_example.price_change SET state = 'approved'
    WHERE change_id = 2 AND state = 'proposed'
    RETURNING change_id, requested_by
)
INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
SELECT change_id, requested_by, 3, 'approve' FROM moved;
SELECT count(*) = 2 AS valid FROM proposal_example.price_change WHERE state = 'approved' \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Once decided, the proposal's requester cannot be rewritten under its decision.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE proposal_example.price_change SET requested_by = 2 WHERE change_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23503' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A second decision on an already decided proposal finds no open row and records nothing.
WITH moved AS (
    UPDATE proposal_example.price_change SET state = 'approved'
    WHERE change_id = 1 AND state = 'proposed'
    RETURNING change_id, requested_by
), decided AS (
    INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
    SELECT change_id, requested_by, 3, 'approve' FROM moved
    RETURNING change_id
)
SELECT count(*) = 0 AS valid FROM decided \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A direct second decision row is stopped by the decision table's primary key.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
VALUES (1, 1, 3, 'reject');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Apply change 1: lock the proposal, update the product only if it is still at the base version,
-- and close the proposal as applied or stale in the same statement.
WITH proposal AS (
    SELECT pc.change_id, pc.product_id, pc.proposed_price, pc.base_version
    FROM proposal_example.price_change pc
    JOIN proposal_example.price_change_decision d
      ON d.change_id = pc.change_id AND d.verdict = 'approve'
    WHERE pc.change_id = 1 AND pc.state = 'approved'
    FOR UPDATE OF pc
), target AS (
    UPDATE proposal_example.product p
    SET price = proposal.proposed_price, version = p.version + 1
    FROM proposal
    WHERE p.product_id = proposal.product_id AND p.version = proposal.base_version
    RETURNING p.product_id
)
UPDATE proposal_example.price_change c
SET state = CASE WHEN EXISTS (SELECT FROM target) THEN 'applied' ELSE 'stale' END,
    closed_at = now()
FROM proposal
WHERE c.change_id = proposal.change_id
RETURNING c.state AS outcome \gset
SELECT :'outcome' = 'applied'
   AND (SELECT price = 120.00 AND version = 1 FROM proposal_example.product WHERE product_id = 1)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Change 2 was approved against version 0. Applying it now marks it stale and leaves the price alone.
WITH proposal AS (
    SELECT pc.change_id, pc.product_id, pc.proposed_price, pc.base_version
    FROM proposal_example.price_change pc
    JOIN proposal_example.price_change_decision d
      ON d.change_id = pc.change_id AND d.verdict = 'approve'
    WHERE pc.change_id = 2 AND pc.state = 'approved'
    FOR UPDATE OF pc
), target AS (
    UPDATE proposal_example.product p
    SET price = proposal.proposed_price, version = p.version + 1
    FROM proposal
    WHERE p.product_id = proposal.product_id AND p.version = proposal.base_version
    RETURNING p.product_id
)
UPDATE proposal_example.price_change c
SET state = CASE WHEN EXISTS (SELECT FROM target) THEN 'applied' ELSE 'stale' END,
    closed_at = now()
FROM proposal
WHERE c.change_id = proposal.change_id
RETURNING c.state AS outcome \gset
SELECT :'outcome' = 'stale'
   AND (SELECT price = 120.00 AND version = 1 FROM proposal_example.product WHERE product_id = 1)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Applying change 1 again finds no approved proposal and changes nothing.
WITH proposal AS (
    SELECT pc.change_id, pc.product_id, pc.proposed_price, pc.base_version
    FROM proposal_example.price_change pc
    JOIN proposal_example.price_change_decision d
      ON d.change_id = pc.change_id AND d.verdict = 'approve'
    WHERE pc.change_id = 1 AND pc.state = 'approved'
    FOR UPDATE OF pc
), target AS (
    UPDATE proposal_example.product p
    SET price = proposal.proposed_price, version = p.version + 1
    FROM proposal
    WHERE p.product_id = proposal.product_id AND p.version = proposal.base_version
    RETURNING p.product_id
), closed AS (
    UPDATE proposal_example.price_change c
    SET state = CASE WHEN EXISTS (SELECT FROM target) THEN 'applied' ELSE 'stale' END,
        closed_at = now()
    FROM proposal
    WHERE c.change_id = proposal.change_id
    RETURNING c.state
)
SELECT count(*) = 0 AS valid FROM closed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT (SELECT version = 1 FROM proposal_example.product WHERE product_id = 1) AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A proposal based on a version the client saw earlier is not recorded.
WITH proposed AS (
    INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
    SELECT 6, product_id, 115.00, version, 2 FROM proposal_example.product
    WHERE product_id = 1 AND version = 0
    RETURNING change_id
)
SELECT count(*) = 0 AS valid FROM proposed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A proposal marked approved without a decision row is not applied.
INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 7, product_id, 99.00, version, 1 FROM proposal_example.product WHERE product_id = 1;
UPDATE proposal_example.price_change SET state = 'approved' WHERE change_id = 7;
WITH proposal AS (
    SELECT pc.change_id, pc.product_id, pc.proposed_price, pc.base_version
    FROM proposal_example.price_change pc
    JOIN proposal_example.price_change_decision d
      ON d.change_id = pc.change_id AND d.verdict = 'approve'
    WHERE pc.change_id = 7 AND pc.state = 'approved'
    FOR UPDATE OF pc
), target AS (
    UPDATE proposal_example.product p
    SET price = proposal.proposed_price, version = p.version + 1
    FROM proposal
    WHERE p.product_id = proposal.product_id AND p.version = proposal.base_version
    RETURNING p.product_id
), closed AS (
    UPDATE proposal_example.price_change c
    SET state = CASE WHEN EXISTS (SELECT FROM target) THEN 'applied' ELSE 'stale' END,
        closed_at = now()
    FROM proposal
    WHERE c.change_id = proposal.change_id
    RETURNING c.state
)
SELECT count(*) = 0 AS valid FROM closed \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
SELECT (SELECT price = 120.00 AND version = 1 FROM proposal_example.product WHERE product_id = 1)
   AS valid \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
UPDATE proposal_example.price_change SET state = 'withdrawn', closed_at = now() WHERE change_id = 7;

-- Only the requester withdraws, and only while the proposal is still open.
INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 3, product_id, 125.00, version, 1 FROM proposal_example.product WHERE product_id = 1;
WITH withdrawn AS (
    UPDATE proposal_example.price_change SET state = 'withdrawn', closed_at = now()
    WHERE change_id = 3 AND state = 'proposed' AND requested_by = 3
    RETURNING change_id
)
SELECT count(*) = 0 AS valid FROM withdrawn \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH withdrawn AS (
    UPDATE proposal_example.price_change SET state = 'withdrawn', closed_at = now()
    WHERE change_id = 3 AND state = 'proposed' AND requested_by = 1
    RETURNING change_id
)
SELECT count(*) = 1 AS valid FROM withdrawn \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif
WITH moved AS (
    UPDATE proposal_example.price_change SET state = 'approved'
    WHERE change_id = 3 AND state = 'proposed'
    RETURNING change_id, requested_by
), decided AS (
    INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
    SELECT change_id, requested_by, 2, 'approve' FROM moved
    RETURNING change_id
)
SELECT count(*) = 0 AS valid FROM decided \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- A final state without a closing time is rejected.
SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
UPDATE proposal_example.price_change SET state = 'rejected', closed_at = NULL WHERE change_id = 3;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23514' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

------------------------------------------------------------------------------
-- Stricter policy: at most one open proposal per product.
------------------------------------------------------------------------------
CREATE UNIQUE INDEX price_change_one_open
    ON proposal_example.price_change (product_id)
    WHERE state IN ('proposed', 'approved');

INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 4, product_id, 130.00, version, 1 FROM proposal_example.product WHERE product_id = 1;

SAVEPOINT rejected_operation;
\set ON_ERROR_STOP off
INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 5, product_id, 135.00, version, 2 FROM proposal_example.product WHERE product_id = 1;
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT rejected_operation;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

-- Once Bob rejects change 4, the product accepts a new proposal.
WITH moved AS (
    UPDATE proposal_example.price_change SET state = 'rejected', closed_at = now()
    WHERE change_id = 4 AND state = 'proposed'
    RETURNING change_id, requested_by
)
INSERT INTO proposal_example.price_change_decision (change_id, requested_by, decided_by, verdict)
SELECT change_id, requested_by, 2, 'reject' FROM moved;
INSERT INTO proposal_example.price_change (change_id, product_id, proposed_price, base_version, requested_by)
SELECT 5, product_id, 135.00, version, 2 FROM proposal_example.product WHERE product_id = 1;
SELECT count(*) = 1 AS valid FROM proposal_example.price_change
WHERE product_id = 1 AND state IN ('proposed', 'approved') \gset
\if :valid
\else
    SELECT 1 / 0 AS assertion_failed;
\endif

ROLLBACK;
