# Candidate Patterns

A backlog of pattern ideas for the book. Every pattern starts life here as a `candidate`. This is the first place to look before writing a new chapter and the first place to add a new idea.

**Scope:** relational schemas for application (OLTP) databases, with PostgreSQL as the reference engine and engine differences noted where they matter. Document, key-value and wide-column modeling and analytics/warehouse modeling are separate books under their own names; their ideas are listed under [Out of scope](#out-of-scope) so they are not lost.

The plan below comes from the source inventory in [research/schema-organization-patterns-2026-11-10.md](research/schema-organization-patterns-2026-11-10.md). Groups follow the situation the reader is in; one chapter is one named pattern; sibling patterns are compared in a short selection panel in each chapter and in the Decision Atlas appendix. Before a chapter cites structure attributed to a book that the inventory verified only by table of contents (Hay, Silverston, Celko, Fowler's *Analysis Patterns*, Ambler and Sadalage, Karwin beyond his slides), check it against the text.

## Workflow

1. **Before writing** — scan the table below. If the idea already exists, reuse its row instead of opening a new one.
2. **New idea** — add a row with status `candidate` and a one-line pitch. No file needed yet.
3. **Accepted** — when you start the chapter, set status to `accepted`, assign the group, and follow [CONTRIBUTING.md](CONTRIBUTING.md) to create `book/ru/<slug>.md`.
4. **Done** — once the `ru` chapter is written (and, ideally, translated), set status to `done`.
5. **Rejected** — if the idea does not earn a chapter, set status to `rejected` and record **why** in Note. Keep the row: a documented "no" saves us from re-litigating it later.

## Legend

| Status      | Meaning                                             |
|-------------|-----------------------------------------------------|
| `candidate` | Proposed, not yet decided                           |
| `accepted`  | Chapter is being written                            |
| `done`      | `ru` chapter written                                |
| `rejected`  | Does not earn a chapter; the reason is in Note      |

## Candidates

| Slug | Pitch | Group | Status | Note |
|------|-------|-------|--------|------|
| `surrogate-key` | Generated key with no business meaning: bigint identity vs UUIDv4 vs UUIDv7/ULID. | identity | candidate | Fowler Identity Field; Ambler Introduce Surrogate Key. |
| `natural-key` | Business attributes as the key, including composite keys, and when they stay stable enough. | identity | candidate | Composite keys live here and in `association-table`. |
| `time-ordered-identifier` | IDs that sort by creation time: UUIDv7, ULID, Snowflake; generation and index locality. | identity | candidate | RFC 9562. |
| `public-identifier` | Expose an internal ID or a separate, possibly prefixed, external one. | identity | candidate | Stripe-style prefixes; their rationale is only in an employee blog. |
| `association-table` | Junction table for many-to-many links, with its own attributes and composite key. | relationships | candidate | Fowler Association Table Mapping; fix for Jaywalking. |
| `table-split` | One-to-one split of optional or rarely read columns into a separate table. | relationships | candidate | Merges `one-to-one-split` and `vertical-partitioning`; keep their motivations apart. |
| `ordered-collection` | User-defined order of rows: positions, uniqueness, concurrent reordering. | relationships | candidate | Added in review; not in the inventory yet. |
| `localized-values` | Translated attributes: translation tables, locale uniqueness, fallback. | relationships | candidate | Added in review; not in the inventory yet. |
| `lookup-table` | Constrained vocabulary: lookup table vs enum type vs CHECK constraint or domain. | reference-and-state | candidate | Absorbs `enum-type` and `check-constraint-domain`; OTLT is its failure mode. |
| `status-history` | Current status plus a log of transitions; allowed transitions enforced in tables. | reference-and-state | candidate | A transition-table FK checks the pair, not the current state; needs concurrency control. |
| `adjacency-list` | Each row references its parent; recursive CTE for traversal. | hierarchies | candidate | Karwin Naive Trees as the failure mode; recursive queries are implementation material. |
| `materialized-path` | Store the ancestor path in the row; ltree, hierarchyid. | hierarchies | candidate | Karwin/Celko name: Path Enumeration. |
| `nested-sets` | Left/right bounds per node for fast subtree reads, costly writes. | hierarchies | candidate | Celko. |
| `closure-table` | Separate table of all ancestor-descendant pairs. | hierarchies | candidate | Karwin; Kimball hierarchy bridge. Two cells of Karwin's comparison table need checking. |
| `single-table-inheritance` | All subtypes in one table with a type column and nullable subtype columns. | types-and-attributes | candidate | Fowler; Rails STI; Hibernate SINGLE_TABLE. |
| `class-table-inheritance` | Supertype table plus one table per subtype sharing the key. | types-and-attributes | candidate | Fowler; Hibernate JOINED; Rails Delegated Types. Shared supertype is an application of it. |
| `concrete-table-inheritance` | One full table per concrete subtype, no shared table. | types-and-attributes | candidate | Fowler; Hibernate TABLE_PER_CLASS. |
| `exclusive-arc` | One nullable FK per possible target plus a CHECK that exactly one is set. | types-and-attributes | candidate | Karwin's fix for Polymorphic Associations. |
| `json-column` | Semi-structured attributes in a JSON/JSONB column, with generated columns and indexes. | types-and-attributes | candidate | Fowler Serialized LOB. |
| `typed-properties` | User-defined attributes with metadata, types and constraints: legitimate extensibility. | types-and-attributes | candidate | Merges `dynamic-property`, `generic-table-structure`, `entity-attribute-value` (designed form). |
| `history-table` | Previous row versions kept in a history table, manually or by native system versioning. | time-and-deletion | candidate | Merges `system-versioned-table`; SQL:2011 system time. |
| `effective-dating` | Rows valid for a business period, with no-overlap constraints. | time-and-deletion | candidate | SQL:2011 application time; PostgreSQL 18 WITHOUT OVERLAPS; Fowler Effectivity. |
| `bitemporal-table` | Both business validity and recorded time on the same rows. | time-and-deletion | candidate | Fowler Bitemporal History. |
| `audit-log` | Append-only record of who changed what, when and why. | time-and-deletion | candidate | Fowler Audit Log; tamper evidence only with an explicit threat model. |
| `soft-delete` | Mark rows deleted instead of removing them, vs a deleted-records archive table. | time-and-deletion | candidate | Sourced disagreement; partial unique index for uniqueness. |
| `party` | One supertype for people and organizations that the rest of the schema references. | domain-structures | candidate | Fowler, Silverston, Hay; verify against the books. |
| `role-object` | Roles a party plays, as separate rows rather than flags or subtypes. | domain-structures | candidate | Fowler Role Object; Accountability folds in as time-qualified relationships. |
| `quantity` | Amount together with its unit, and conversion between units. | domain-structures | candidate | Fowler Quantity. |
| `observation` | Measurements recorded as facts with phenomenon, method and time. | domain-structures | candidate | Fowler Observation. |
| `bill-of-materials` | Components and assemblies with quantities, as a graph of parts. | domain-structures | candidate | Silverston, Celko. |
| `double-entry-ledger` | Money moves as balanced entries between accounts; balances derived or stored. | domain-structures | candidate | Absorbs `derived-balance` and `inventory-movement` as variants. |
| `version-column` | Optimistic locking through a version or rowversion column. | reliable-writes | candidate | Fowler Optimistic Offline Lock. |
| `reservation` | Temporary claims on capacity or time slots: expiry, confirmation, concurrent acquisition. | reliable-writes | candidate | Added in review; inventory holds and bookings are variants. |
| `idempotency-record` | Store request keys and responses so retries do not repeat side effects. | reliable-writes | candidate | Absorbs `processed-messages-table` as the consumer-side variant. |
| `transactional-outbox` | Write events to an outbox table in the same transaction as the data. | reliable-writes | candidate | microservices.io; Debezium. |
| `queue-table` | Jobs in a table, claimed with SELECT ... FOR UPDATE SKIP LOCKED. | reliable-writes | candidate | Craig Ringer's original post was unreachable. |
| `shared-schema` | All tenants in shared tables keyed by tenant_id, with row-level security. | tenant-isolation | candidate | AWS pool model; RLS is implementation material. |
| `schema-per-tenant` | One schema per tenant in a shared database. | tenant-isolation | candidate | AWS bridge model; Citus schema-based sharding. |
| `database-per-tenant` | One database per tenant. | tenant-isolation | candidate | AWS silo model. |
| `summary-table` | Precomputed aggregates and counters kept in sync with the source rows. | growth-and-change | candidate | Absorbs `counter-cache`; materialized views as an implementation. |
| `table-partitioning` | Split a growing table by range, list or hash inside one database. | growth-and-change | candidate | Renamed from `horizontal-partitioning`. |
| `expand-contract` | Change the schema in backward-compatible steps: expand, migrate, contract. | growth-and-change | candidate | Parallel Change; Ambler and Sadalage transition period. |
| `delimited-lists` | Several values packed into one string column. | anti-patterns | candidate | Karwin: Jaywalking. |
| `mandatory-surrogates` | An `id` column on every table, even where a natural or composite key fits. | anti-patterns | candidate | Karwin: ID Required. |
| `missing-foreign-keys` | References without foreign key constraints. | anti-patterns | candidate | Karwin: Keyless Entry. |
| `repeated-columns` | `tag1`, `tag2`, `tag3` instead of a child table. | anti-patterns | candidate | Karwin: Multicolumn Attributes. |
| `polymorphic-associations` | `(type, id)` reference that no foreign key can check. | anti-patterns | candidate | Karwin: Polymorphic Associations. Fixes: exclusive arc, per-target association tables, shared supertype. |
| `untyped-properties` | Generic attribute/value rows with no types or constraints. | anti-patterns | candidate | Karwin: Entity-Attribute-Value. Pairs with `typed-properties`. |
| `volatile-enums` | Enum or CHECK lists that change with business data. | anti-patterns | candidate | Karwin: 31 Flavors. Stable enums stay legitimate. |
| `fixed-depth-queries` | Tree queries hard-coded to a fixed number of self-joins. | anti-patterns | candidate | Karwin: Naive Trees. Adjacency list itself stays legitimate. |
| `cloned-tables` | One table per year, customer or tenant with the same columns. | anti-patterns | candidate | Karwin: Metadata Tribbles. |
| `inexact-arithmetic` | Money and exact quantities in floating-point columns. | anti-patterns | candidate | Karwin: Rounding Errors. |

Appendices planned alongside the chapters (not patterns, not voted on): `decision-atlas` — comparison tables for every family of alternatives; `sql-lab` — runnable PostgreSQL examples with a pinned engine version.

## Covered inside other chapters

Native system versioning (`history-table`), counter caches (`summary-table`), derived balances and inventory movements (`double-entry-ledger`), consumer-side deduplication (`idempotency-record`), shared supertype (`class-table-inheritance`, `polymorphic-associations`), one true lookup table (`lookup-table`), recursive queries, partial indexes and row-level security as implementation material.

## Deferred

Kept for a later edition of this book: hi-lo allocation, nested intervals, unlogged staging tables, edition-based redefinition, standalone tamper-evident ledgers, dedicated chapters for Accountability, Identification Scheme, Agreement and Order, and Celko's auxiliary tables (calendar, numbers).

## Out of scope

Belong to the separate books, not this one: document, key-value and wide-column modeling (MongoDB patterns, DynamoDB single-table design, Cassandra query-first design, Cosmos DB); analytics and warehouse modeling (star and snowflake schemas, slowly changing dimensions, Data Vault, anchor modeling, one big table); distributed sharding; event sourcing, CQRS read models and saga state; native graph models.
