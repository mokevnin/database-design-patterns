# Candidate Patterns

A backlog of pattern ideas for the book. Every pattern starts life here as a `candidate`. This is the first place to look before writing a new chapter and the first place to add a new idea.

**Scope:** relational schemas for application (OLTP) databases, with PostgreSQL as the reference engine and engine differences noted where they matter. Document, key-value and wide-column modeling and analytics/warehouse modeling are separate books under their own names; their ideas are listed under [Out of scope](#out-of-scope) so they are not lost.

The plan below comes from the source inventory in [research/schema-organization-patterns-2026-11-10.md](research/schema-organization-patterns-2026-11-10.md). Groups follow the situation the reader is in; one chapter is one named pattern; sibling patterns are compared in a short selection panel in each chapter and in the Decision Atlas appendix. Before a chapter cites structure attributed to a book that the inventory verified only by table of contents (Hay, Silverston, Celko, Fowler's *Analysis Patterns*, Ambler and Sadalage, Karwin beyond his slides), check it against the text.

## Workflow

1. **Before writing** — scan the table below. If the idea already exists, reuse its row instead of opening a new one.
2. **New idea** — add a row with status `candidate` and a one-line pitch. No file needed yet.
3. **Accepted** — when you start the chapter, set status to `accepted`, assign the group, and follow [CONTRIBUTING.md](CONTRIBUTING.md) to create `book/en/<slug>.md`.
4. **Done** — once the `en` chapter is written, set status to `done`.
5. **Rejected** — if the idea does not earn a chapter, set status to `rejected` and record **why** in Note. Keep the row: a documented "no" saves us from re-litigating it later.

## Legend

| Status      | Meaning                                             |
|-------------|-----------------------------------------------------|
| `candidate` | Proposed, not yet decided                           |
| `accepted`  | Chapter is being written                            |
| `done`      | `en` chapter written                                |
| `rejected`  | Does not earn a chapter; the reason is in Note      |

## Candidates

| Slug | Pitch | Group | Status | Note |
|------|-------|-------|--------|------|
| `surrogate-key` | Generated key with no business meaning: bigint identity vs UUIDv4 vs UUIDv7/ULID. | identity | done | Fowler Identity Field; Ambler Introduce Surrogate Key. |
| `natural-key` | Business attributes as the key, including composite keys, and when they stay stable enough. | identity | done | Composite keys live here and in `association-table`. |
| `time-ordered-identifier` | IDs that sort by creation time: UUIDv7, ULID, Snowflake; generation and index locality. | identity | done | RFC 9562. |
| `public-identifier` | Expose an internal ID or a separate, possibly prefixed, external one. | identity | done | Stripe-style prefixes; their rationale is only in an employee blog. |
| `canonical-value` | One normalized form (Unicode normalization plus case folding) stored or indexed beside the entered value and made unique. | identity | done | Added after reviewing awesome-database-design ("Character Set and Collation"); PostgreSQL 18 `casefold()`, nondeterministic collations. |
| `hashed-secret` | Store verifiers, not secrets: slow salted hashes for passwords, digests as lookup keys for random tokens, with expiry and single use. | identity | done | Positive form of Karwin's Readable Passwords. Reverses the inventory's "security more than structure" call: the hash format, digest key, lifecycle columns and one-open-token index are schema decisions. |
| `external-reference` | IDs issued by other systems (payment provider, CRM, OIDC `iss`/`sub`): a column or a cross-reference table, uniqueness scoped by system and environment, the first-arrival race. The external ID is never our primary key: it is a unique attribute next to our own key. | identity | done | Fowler Identification Scheme (Analysis Patterns ch. 5, TOC-verified), moved from Deferred. Inbound counterpart of `public-identifier`; when writing, resolve that chapter's “External ID” alias so the two names do not collide. Exception to discuss explicitly: mirror tables of foreign data, such as an inbox of provider webhook events, may key on the provider event ID as a deduplication key (see `idempotency-record`). Merges and relinking belong to `record-merge`. |
| `record-merge` | Merging duplicate records: a survivor, `merged_into` on the absorbed row, re-pointing references, redirecting old IDs, undoing a wrong merge. | identity | candidate | Fowler Object Merge and Object Equivalence (Analysis Patterns ch. 5, TOC-verified). Replaces the matching paragraph in `party`. Write after `dependent-table` and `external-reference`. |
| `document-number` | Per-scope sequential numbers (invoice numbers, issue numbers per project): a counter row per scope, `UNIQUE (scope, number)`, gapless only where the law requires it. | identity | candidate | PostgreSQL sequences are not gapless by design; Karwin Pseudokey Neat-Freak as the failure mode (TOC-only); EU VAT Directive 2006/112/EC Art. 226(2) for sequential invoice numbers (verify the text). |
| `association-table` | Junction table for many-to-many links, with its own attributes and composite key. | relationships | done | Fowler Association Table Mapping; fix for Jaywalking. |
| `table-split` | One-to-one split of optional or rarely read columns into a separate table. | relationships | done | Merges `one-to-one-split` and `vertical-partitioning`; keep their motivations apart. Extended: personal data in a separate optional table so erasure keeps referring records; Embedded Value named in the alternatives. |
| `dependent-table` | Rows owned by a parent and what deleting or re-keying the parent does: owned children cascade, references restrict, optional links set null (including `SET NULL (cols)`); an index on every referencing column, large cascades in batches, ORM-side cascades that bypass the database. | relationships | done | Fowler Dependent Mapping and Foreign Key Mapping; research `foreign-key-reference`. Renamed from `cascading-delete`: the chapter covers all referential actions, and cascade is often the one it advises against. The soft-delete form of a cascade belongs in `soft-delete`. |
| `file-reference` | Files stored outside the database: a metadata row (storage key, checksum, size, upload state), orphan cleanup in both directions, `bytea` vs external storage. | relationships | candidate | Karwin Phantom Files (TOC-only); Rails Active Storage blobs/attachments, whose polymorphic attachment table is a useful contrast with `polymorphic-associations`. |
| `ordered-collection` | User-defined order of rows: positions, uniqueness, concurrent reordering. | relationships | done | Added in review; not in the inventory yet. |
| `localized-values` | Translated attributes: translation tables, locale uniqueness, fallback. | relationships | done | Added in review; not in the inventory yet. |
| `lookup-table` | Constrained vocabulary: lookup table vs enum type vs CHECK constraint or domain. | reference-and-state | done | Absorbs `enum-type` and `check-constraint-domain`; OTLT is its failure mode. |
| `status-history` | Current status plus a log of transitions; allowed transitions enforced in tables. | reference-and-state | done | A transition-table FK checks the pair, not the current state; needs concurrency control. |
| `proposed-change` | Changes that need approval or a publish step: draft and published versions side by side, or pending change rows applied on approval, with approver ≠ requester enforced. | reference-and-state | candidate | Also known as maker-checker, four-eyes. Fowler Proposed and Implemented Action (Analysis Patterns ch. 8, TOC-only: check against the text). Fowler's eaaDev Proposed Object page is an empty stub; do not cite it. `bill-of-materials` shows draft/released for one domain only. |
| `adjacency-list` | Each row references its parent; recursive CTE for traversal. | hierarchies | done | Karwin Naive Trees as the failure mode; recursive queries are implementation material. |
| `materialized-path` | Store the ancestor path in the row; ltree, hierarchyid. | hierarchies | done | Karwin/Celko name: Path Enumeration. |
| `nested-sets` | Left/right bounds per node for fast subtree reads, costly writes. | hierarchies | done | Celko. |
| `closure-table` | Separate table of all ancestor-descendant pairs. | hierarchies | done | Karwin; Kimball hierarchy bridge. Two cells of Karwin's comparison table need checking. |
| `graph-edges` | General many-to-many self-references: an edge table, canonical order for symmetric edges by CHECK, traversal with `WITH RECURSIVE … CYCLE`. | hierarchies | candidate | SQL Server graph tables; PostgreSQL `CYCLE` clause; Celko Trees and Hierarchies (TOC-only). If accepted, rename the group to “Hierarchies and Graphs”. Only `closure-table` touches DAGs today. |
| `single-table-inheritance` | All subtypes in one table with a type column and nullable subtype columns. | types-and-attributes | done | Fowler; Rails STI; Hibernate SINGLE_TABLE. |
| `class-table-inheritance` | Supertype table plus one table per subtype sharing the key. | types-and-attributes | done | Fowler; Hibernate JOINED; Rails Delegated Types. Shared supertype is an application of it. |
| `concrete-table-inheritance` | One full table per concrete subtype, no shared table. | types-and-attributes | done | Fowler; Hibernate TABLE_PER_CLASS. |
| `exclusive-arc` | One nullable FK per possible target plus a CHECK that exactly one is set. | types-and-attributes | done | Karwin's fix for Polymorphic Associations. |
| `json-column` | Semi-structured attributes in a JSON/JSONB column, with generated columns and indexes. | types-and-attributes | done | Fowler Serialized LOB. |
| `embedded-value` | A value object stored as several columns of its owner. | types-and-attributes | rejected | Folded: `quantity` already is an embedded value and gains the column-group CHECK (`num_nulls`) and composite types/domains; `table-split` names Embedded Value in its alternatives; `repeated-columns` already defends fixed tuples. |
| `typed-properties` | User-defined attributes with metadata, types and constraints: legitimate extensibility. | types-and-attributes | done | Merges `dynamic-property`, `generic-table-structure`, `entity-attribute-value` (designed form). |
| `history-table` | Previous row versions kept in a history table, manually or by native system versioning. | time-and-deletion | done | Merges `system-versioned-table`; SQL:2011 system time. |
| `effective-dating` | Rows valid for a business period, with no-overlap constraints. | time-and-deletion | done | SQL:2011 application time; PostgreSQL 18 WITHOUT OVERLAPS; Fowler Effectivity. |
| `bitemporal-table` | Both business validity and recorded time on the same rows. | time-and-deletion | done | Fowler Bitemporal History. |
| `audit-log` | Append-only record of who changed what, when and why. | time-and-deletion | done | Fowler Audit Log; tamper evidence only with an explicit threat model. |
| `append-only-table` | Immutable rows: insert-only tables, corrections as new rows. | time-and-deletion | rejected | Already covered locally where it matters: guard triggers and reversals in `double-entry-ledger`, grant-based append-only in `audit-log`, immutable releases in `bill-of-materials`, corrections in `bitemporal-table`. A current-state projection over an event log drifts into event sourcing (out of scope). |
| `crypto-shredding` | Personal data encrypted per subject; erasure deletes the key. | time-and-deletion | rejected | Without key management the schema residue is “personal data in a separate table keyed by subject”, which goes into `table-split` as a planned extension. Fowler Datensparsamkeit is about data minimization and does not support this row. |
| `activity-feed` | User-facing stream of actions (actor, verb, object, target). | time-and-deletion | rejected | Fan-out on write vs read is a scaling and application concern; the schema core is a polymorphic object reference (`polymorphic-associations`) plus per-recipient rows, and `table-partitioning` already uses an activity table as its example. A record changelog is `audit-log` plus `history-table`. A narrow “notification inbox” may be reconsidered later. |
| `soft-delete` | Mark rows deleted instead of removing them, vs a deleted-records archive table. | time-and-deletion | done | Sourced disagreement; partial unique index for uniqueness. Extended with an aggregate cascade by deletion operation ID, so a restore brings back exactly the rows that operation hid. |
| `time-point` | Storing instants and dates: `timestamptz` vs `date` vs local time + IANA zone for future events, precision, half-open ranges, which clock. | time-and-deletion | done | Fowler Time Point (eaaDev). No chapter covers time zones; every temporal chapter depends on it. |
| `captured-value` | Copy what was true at the time of the fact (price, product name, address, tax rate, exchange rate) into the order or invoice line; a fact, not a cache, never re-synced. | time-and-deletion | done | The legitimate half of “denormalization”; contrast with a synced copy (cache), which stays in `summary-table`. Sibling of referencing an immutable version (`bill-of-materials` pinning, `effective-dating`). Worked variant: the applied exchange rate. |
| `recurrence-rule` | Repeating events: a rule row plus exceptions plus optionally materialized occurrences, stored as local time with an IANA zone. | time-and-deletion | candidate | RFC 5545 (RRULE, EXDATE, RECURRENCE-ID); Fowler Recurring Events for Calendars (Schedule, Schedule Element). Write after `time-point`. |
| `archive-table` | Move old, closed (not deleted) rows out of live tables: archive schema or detached partitions, its own retention and access, queries that span live and archive, restore as an explicit import. | time-and-deletion | candidate | The deleted-record archive stays in `soft-delete` and partition detach in `table-partitioning`; this chapter links to both and covers the retention-tier case neither owns. Review suggested rejecting it as covered; narrowed instead. |
| `party` | One supertype for people and organizations that the rest of the schema references. | domain-structures | done | Fowler, Silverston, Hay; verify against the books. |
| `role-object` | Roles a party plays, as separate rows rather than flags or subtypes. | domain-structures | done | Fowler Role Object; Accountability folds in as time-qualified relationships. |
| `quantity` | Amount together with its unit, and conversion between units. | domain-structures | done | Fowler Quantity. Extended with Embedded Value: a CHECK that a column group is all set or all null, and why a composite type cannot carry the unit FK. Allocation of amounts stays in `inexact-arithmetic`. |
| `observation` | Measurements recorded as facts with phenomenon, method and time. | domain-structures | done | Fowler Observation. |
| `bill-of-materials` | Components and assemblies with quantities, as a graph of parts. | domain-structures | done | Silverston, Celko. |
| `double-entry-ledger` | Money moves as balanced entries between accounts; balances derived or stored. | domain-structures | done | Absorbs `derived-balance` and `inventory-movement` as variants. |
| `permission-grant` | Role, permission and assignment tables scoped to a tenant or resource, with separation-of-duty constraints. | domain-structures | candidate | NIST RBAC (ANSI INCITS 359-2004); Zanzibar relation tuples (USENIX ATC 2019). Unsure it earns a chapter; name must not collide with `role-object`. |
| `exchange-rate` | Dated currency quotes and the rate applied to a conversion. | domain-structures | rejected | Folded into `captured-value` as a worked variant: dated quotes are `effective-dating`, the applied rate is a captured value, never summing across currencies is `quantity` and `double-entry-ledger`. Fowler Money Bag (eaaDev) is an empty stub. |
| `version-column` | Optimistic locking through a version or rowversion column. | reliable-writes | done | Fowler Optimistic Offline Lock. |
| `reservation` | Temporary claims on capacity or time slots: expiry, confirmation, concurrent acquisition. | reliable-writes | done | Added in review; inventory holds and bookings are variants. |
| `idempotency-record` | Store request keys and responses so retries do not repeat side effects. | reliable-writes | done | Absorbs `processed-messages-table` as the consumer-side variant. |
| `transactional-outbox` | Write events to an outbox table in the same transaction as the data. | reliable-writes | done | microservices.io; Debezium. |
| `queue-table` | Jobs in a table, claimed with SELECT ... FOR UPDATE SKIP LOCKED. | reliable-writes | done | Craig Ringer's original post was unreachable. |
| `edit-lock` | Pessimistic offline lock: one lock row per resource with owner, expiry and a generation; insert to acquire, takeover after expiry or by an administrator, stale holders rejected on write. | reliable-writes | candidate | Fowler Pessimistic Offline Lock and Coarse-Grained Lock (PoEAA); Solid Queue `semaphores`. Renamed from `lock-table` to avoid SQL `LOCK TABLE`. Review suggested folding it into `version-column`; kept as a chapter because readers look for pessimistic locking by name. Reuse the lease/generation mechanism from `queue-table` rather than re-deriving it. |
| `shared-schema` | All tenants in shared tables keyed by tenant_id, with row-level security. | tenant-isolation | done | AWS pool model; RLS is implementation material. |
| `schema-per-tenant` | One schema per tenant in a shared database. | tenant-isolation | done | AWS bridge model; Citus schema-based sharding. |
| `database-per-tenant` | One database per tenant. | tenant-isolation | done | AWS silo model. |
| `summary-table` | Precomputed aggregates and counters kept in sync with the source rows. | growth-and-change | done | Absorbs `counter-cache`; materialized views as an implementation. |
| `redundant-column` | A parent attribute copied into children for constraints or queries. | growth-and-change | rejected | Composite FKs through a copied attribute are already used in about nine chapters, `tenant_id` is the core of `shared-schema`, trigger sync belongs to `summary-table`, and the slug is close to the anti-pattern `repeated-columns`. The cache-vs-fact contrast lives in `captured-value`. |
| `table-partitioning` | Split a growing table by range, list or hash inside one database. | growth-and-change | done | Renamed from `horizontal-partitioning`. |
| `expand-contract` | Change the schema in backward-compatible steps: expand, migrate, contract. | growth-and-change | done | Parallel Change; Ambler and Sadalage transition period. |
| `delimited-lists` | Several values packed into one string column. | anti-patterns | done | Karwin: Jaywalking. |
| `mandatory-surrogates` | An `id` column on every table, even where a natural or composite key fits. | anti-patterns | done | Karwin: ID Required. |
| `missing-foreign-keys` | References without foreign key constraints. | anti-patterns | done | Karwin: Keyless Entry. |
| `repeated-columns` | `tag1`, `tag2`, `tag3` instead of a child table. | anti-patterns | done | Karwin: Multicolumn Attributes. |
| `polymorphic-associations` | `(type, id)` reference that no foreign key can check. | anti-patterns | done | Karwin: Polymorphic Associations. Fixes: exclusive arc, per-target association tables, shared supertype. |
| `untyped-properties` | Generic attribute/value rows with no types or constraints. | anti-patterns | done | Karwin: Entity-Attribute-Value. Pairs with `typed-properties`. |
| `volatile-enums` | Enum or CHECK lists that change with business data. | anti-patterns | done | Karwin: 31 Flavors. Stable enums stay legitimate. |
| `fixed-depth-queries` | Tree queries hard-coded to a fixed number of self-joins. | anti-patterns | done | Karwin: Naive Trees. Adjacency list itself stays legitimate. |
| `cloned-tables` | One table per year, customer or tenant with the same columns. | anti-patterns | done | Karwin: Metadata Tribbles. |
| `inexact-arithmetic` | Money and exact quantities in floating-point columns. | anti-patterns | done | Karwin: Rounding Errors. |
| `sentinel-rows` | Fake “Unknown” or `id = 0` rows standing in for a missing reference, hiding absent data and skewing aggregates. | anti-patterns | done | Fowler Special Case (PoEAA) applied to tables. Defensible case: a real `System` actor row. Kimball unknown member is a warehouse idiom; cite as context only. |
| `guessable-links` | A public or share-by-link URL whose only secret is a sequential ID or a deterministic encoding of it (`md5(id)`, Hashids/Sqids), so anyone can enumerate other links. | anti-patterns | done | OWASP API Security Top 10 2023 API1 (Broken Object Level Authorization) and the IDOR cheat sheet; W3C TAG “Good Practices for Capability URLs”. Fix: a random capability token stored as a digest (`hashed-secret`), scoped, expiring and revocable, separate from the object's `public-identifier`; ordinary URLs still need authorization checks. Defensible: an exposed ID behind real access control. |

Appendices planned alongside the chapters (not patterns, not voted on): `decision-atlas` — comparison tables for every family of alternatives; `sql-lab` — runnable PostgreSQL examples with a pinned engine version.

## Covered inside other chapters

Native system versioning (`history-table`), counter caches (`summary-table`), derived balances and inventory movements (`double-entry-ledger`), consumer-side deduplication (`idempotency-record`), allocation of amounts into parts (`inexact-arithmetic`), immutable rows (`double-entry-ledger`, `audit-log`, `bill-of-materials`), the deleted-record archive (`soft-delete`), shared supertype (`class-table-inheritance`, `polymorphic-associations`), one true lookup table (`lookup-table`), recursive queries, partial indexes and row-level security as implementation material.

## Deferred

Kept for a later edition of this book: hi-lo allocation, nested intervals, unlogged staging tables, edition-based redefinition, standalone tamper-evident ledgers, dedicated chapters for Accountability, Agreement and Order, and Celko's auxiliary tables (calendar, numbers).

## Out of scope

Belong to the separate books, not this one: document, key-value and wide-column modeling (MongoDB patterns, DynamoDB single-table design, Cassandra query-first design, Cosmos DB); analytics and warehouse modeling (star and snowflake schemas, slowly changing dimensions, Data Vault, anchor modeling, one big table); distributed sharding; event sourcing, CQRS read models and saga state; native graph models.
