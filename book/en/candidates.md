# Candidates and voting

Which topics should the book cover next? These are short proposals for new chapters. They are not accepted yet, and some may merge into existing patterns. The last ten topics are proposed anti-patterns.

The full list, sources, overlaps, and current statuses are in [CANDIDATES.md](https://github.com/mokevnin/database-design-patterns/blob/main/CANDIDATES.md).

## How to vote

Open “Discuss / vote” next to a topic and add a 👍 reaction to the opening post in the issue. You can support several topics. Comments describing a task where you need the pattern are especially useful.

Russian, English, and Spanish are welcome; participation requires a GitHub account. Votes indicate reader interest; inclusion remains an editorial decision.

| Topic | Identifier | Discussion |
|---|---|---|
| Association table — store many-to-many relationships with their own attributes and a composite key. | `association-table` | Discussion not opened yet |
| Table split — move optional or rarely read columns into a separate table with a one-to-one relationship. | `table-split` | Discussion not opened yet |
| Ordered collection — store a user-defined row order and safely change it under concurrent requests. | `ordered-collection` | Discussion not opened yet |
| Localized values — store attribute translations, enforce uniqueness per locale, and select a fallback translation. | `localized-values` | Discussion not opened yet |
| Lookup table — constrain allowed values and choose between a lookup table, enum, CHECK, and domain. | `lookup-table` | Discussion not opened yet |
| Status history — store the current status and transitions, preventing invalid changes even under concurrent writes. | `status-history` | Discussion not opened yet |
| Adjacency list — represent a tree with parent references and traverse it using recursive CTEs. | `adjacency-list` | Discussion not opened yet |
| Materialized path — store each row's ancestor path to query branches of a tree. | `materialized-path` | Discussion not opened yet |
| Nested sets — speed up subtree reads with left and right node bounds at the cost of more complex updates. | `nested-sets` | Discussion not opened yet |
| Closure Table — store all ancestor–descendant pairs in a separate table for hierarchy queries. | `closure-table` | Discussion not opened yet |
| Single-table inheritance — store all subtypes in one table with a type discriminator and nullable columns. | `single-table-inheritance` | Discussion not opened yet |
| Class-table inheritance — split shared and specific attributes between a supertype table and subtype tables with a shared key. | `class-table-inheritance` | Discussion not opened yet |
| Concrete-table inheritance — store each concrete subtype in its own complete table without a shared table. | `concrete-table-inheritance` | Discussion not opened yet |
| Exclusive arc — reference exactly one of several tables using separate foreign keys and a CHECK constraint. | `exclusive-arc` | Discussion not opened yet |
| JSON column — store semi-structured attributes in JSON/JSONB and speed up access with indexes and generated columns. | `json-column` | Discussion not opened yet |
| Typed properties — let users add attributes with metadata, types, and constraints. | `typed-properties` | Discussion not opened yet |
| History table — retain previous row versions manually or through the database's native system versioning. | `history-table` | Discussion not opened yet |
| Effective dating — define a record's business validity period and prevent overlapping periods. | `effective-dating` | Discussion not opened yet |
| Bitemporal table — distinguish when a fact was valid in the business from when the database learned about it. | `bitemporal-table` | Discussion not opened yet |
| Audit log — keep an append-only record of who changed what, when, and why. | `audit-log` | Discussion not opened yet |
| Soft delete — mark rows as deleted and compare this approach with moving them to an archive, accounting for data uniqueness. | `soft-delete` | Discussion not opened yet |
| Party — unify people and organizations under a common supertype that the rest of the schema references. | `party` | Discussion not opened yet |
| Role object — store a person's or organization's roles as separate rows instead of flags or subtypes. | `role-object` | Discussion not opened yet |
| Quantity — store a number together with its unit of measurement and convert between units. | `quantity` | Discussion not opened yet |
| Observation — record measurements as facts with a phenomenon, method, and time. | `observation` | Discussion not opened yet |
| Bill of materials — represent parts and assemblies as a component graph with quantities. | `bill-of-materials` | Discussion not opened yet |
| Double-entry ledger — track money movements as balanced entries between accounts and derive balances from them. | `double-entry-ledger` | Discussion not opened yet |
| Version column — prevent lost updates under concurrent writes using optimistic locking. | `version-column` | Discussion not opened yet |
| Reservation — temporarily claim a resource or time slot with confirmation, expiry, and protection against double booking. | `reservation` | Discussion not opened yet |
| Idempotency record — store request keys and responses so retries do not perform the action again. | `idempotency-record` | Discussion not opened yet |
| Transactional outbox — write events to an outbox table in the same transaction as the data change. | `transactional-outbox` | Discussion not opened yet |
| Queue table — store jobs in the database and distribute them among workers using SELECT FOR UPDATE SKIP LOCKED. | `queue-table` | Discussion not opened yet |
| Shared schema — store tenant data in shared tables with tenant_id and row-level isolation. | `shared-schema` | Discussion not opened yet |
| Schema per tenant — isolate each tenant's data in a separate schema within a shared database. | `schema-per-tenant` | Discussion not opened yet |
| Database per tenant — give each tenant a separate database for isolation. | `database-per-tenant` | Discussion not opened yet |
| Summary table — speed up reads with precomputed aggregates and counters kept consistent with source rows. | `summary-table` | Discussion not opened yet |
| Table partitioning — split a growing table by range, list, or hash within one database. | `table-partitioning` | Discussion not opened yet |
| Expand and contract — change the schema in compatible steps: add the new structure, migrate data, and remove the old structure. | `expand-contract` | Discussion not opened yet |
| Delimited lists — packing several values into one string column hinders searches, relationships, and integrity checks. | `delimited-lists` | Discussion not opened yet |
| Mandatory surrogates — an id column on every table can obscure a suitable natural or composite key. | `mandatory-surrogates` | Discussion not opened yet |
| Missing foreign keys — references without constraints allow rows to point to records that do not exist. | `missing-foreign-keys` | Discussion not opened yet |
| Repeated columns — fields such as tag1, tag2, and tag3 limit the number of values and complicate queries and constraints. | `repeated-columns` | Discussion not opened yet |
| Polymorphic associations — a reference formed from a type and an identifier prevents the database from checking its target with a regular foreign key. | `polymorphic-associations` | Discussion not opened yet |
| Untyped properties — generic attribute–value rows without types or constraints let invalid data through. | `untyped-properties` | Discussion not opened yet |
| Volatile enums — business data in an enum or CHECK list forces schema changes whenever the set of values changes. | `volatile-enums` | Discussion not opened yet |
| Fixed-depth queries — a tree query with a fixed number of self-joins misses nodes beyond that depth. | `fixed-depth-queries` | Discussion not opened yet |
| Cloned tables — identical tables for each year or customer multiply migrations and complicate queries across them. | `cloned-tables` | Discussion not opened yet |
| Inexact arithmetic — storing money and exact quantities in floating-point columns causes rounding errors. | `inexact-arithmetic` | Discussion not opened yet |
