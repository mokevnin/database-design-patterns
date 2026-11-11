# Schema organization patterns: source inventory

Checked on 2026-11-10 against an empty `CANDIDATES.md`. The request was to find every known way of organizing database structure for different tasks and situations. This note is an inventory for choosing chapters; it changes nothing in the backlog. Slugs are editorial proposals in kebab-case. Each entry keeps the names the sources themselves use under "Names in sources". Grouping, overlap judgments and chapter recommendations are editorial assessments.

## Scope and method

Scope: logical and physical structure of a database schema: tables, keys, constraints, and the column and table shapes that recur for a given problem. Document, key-value and wide-column stores are included where vendors publish named modeling patterns. Pure query techniques, indexing tactics, ORM behaviour and application-architecture patterns are included only when they dictate a table shape, such as the outbox table or the version column.

Sources were swept in parallel by source family:

- the PostgreSQL 18 manual and Citus 13 docs;
- SQL Server, MariaDB, Db2, MySQL 8.4, Oracle and SQLite docs, plus the SQL:2011 temporal paper;
- MongoDB, DynamoDB, Cassandra and Cosmos DB modeling guides;
- originator pages: RFC 9562, ULID, Snowflake, Stripe, Rails, Django, Hibernate, Laravel, microservices.io, Debezium, TigerBeetle, Square, Modern Treasury, Azure and AWS SaaS guidance, and job-queue libraries;
- analytics and methodology catalogs: Kimball Group techniques, Linstedt, anchormodeling.com, martinfowler.com, Ambler and Sadalage;
- published tables of contents for the books: Karwin, Hay, Silverston, Fowler's *Analysis Patterns*, Celko.

Every source cited was fetched for this note, except where an entry says otherwise. Verification levels are marked inline:

- **fetched**: the page was read and the claim is taken from it.
- **TOC fetched**: only the publisher's table of contents was read. The name is verified; structure and trade-offs come from knowledge of the book and should be treated as unverified until checked against the text.
- **unverified**: no primary source was found or reachable; the entry says why.
- **blog** or **opinion**: cited only when the author originated the idea or the source is the vendor's own engineering writing.

**Structure** lines are editorial synthesis: the column lists and DDL fragments (for example the events table, audit-log columns, generic queue columns, the single-table-inheritance `CHECK`, `num_nonnulls`, and the partial unique index for soft delete) are illustrative sketches written for this note. Only quoted or explicitly attributed statements are source-verified.

Entry format: situation, structure, trade-offs, names in sources, sources. Each pattern has one `###` heading with its proposed slug. Anti-patterns are collected in their own section. A dedup table maps the same idea across sources. A final list collects every source consulted.

## Identity and keys

Ambler's [Choosing a Primary Key: Natural or Surrogate?](https://agiledata.org/essays/keys.html) (fetched) is the most complete single-page vocabulary: key, composite, natural, surrogate, candidate, primary, alternate and foreign keys, with surrogate generation strategies "database-assigned (incremental)", `MAX()+1`, UUIDs/GUIDs and HIGH-LOW.

### surrogate-key

- **Situation:** Natural identifiers are missing, mutable, composite, sensitive or long, and the key will be referenced by many FKs.
- **Structure:** A meaningless system-generated key column (identity/sequence integer or UUID) as PK; natural candidate keys still get `UNIQUE` constraints.
- **Trade-offs:** Stable, compact FKs and easy ORM mapping; nothing stops duplicate real-world rows unless the natural key is also constrained. PostgreSQL identity columns "do not guarantee uniqueness" by themselves (add a PK/UNIQUE), and sequences leave gaps ("nextval and setval calls are never rolled back"), so they cannot provide gapless numbering. On clustered-index engines the PK choice is physical: InnoDB stores every secondary index entry with the PK, so "it is advantageous to have a short primary key"; SQLite's rowid alias needs the declared type to be exactly `INTEGER`.
- **Names in sources:** Identity Field (Fowler PoEAA); surrogate key (Ambler, Kimball "Dimension surrogate keys"); Introduce Surrogate Key, Replace Surrogate Key With Natural Key, Consolidate Key Strategy (Ambler/Sadalage refactorings); overuse is Karwin's "ID Required", renumbering is "Pseudokey Neat-Freak".
- **Sources:** Fowler, [Identity Field](https://martinfowler.com/eaaCatalog/identityField.html) (catalog fetched); Ambler (above); PostgreSQL, [Identity Columns](https://www.postgresql.org/docs/current/ddl-identity-columns.html), [CREATE SEQUENCE](https://www.postgresql.org/docs/current/sql-createsequence.html); MySQL, [Clustered and Secondary Indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html); SQLite, [CREATE TABLE: ROWIDs and the INTEGER PRIMARY KEY](https://www.sqlite.org/lang_createtable.html) (all fetched).

### natural-key

- **Situation:** A stable, unique, business-owned identifier exists (ISO country code, currency code, a junction table's pair of FKs).
- **Structure:** Use it as the PK; FKs carry meaningful values, often avoiding joins to lookup tables.
- **Trade-offs:** Readable data and enforced business uniqueness; changes cascade through every FK and "stable" business keys often turn out not to be. Kimball adds "durable" and "supernatural" keys for warehouse identity across source changes.
- **Names in sources:** natural key, candidate key, alternate key (Ambler); "Natural, durable and supernatural keys" (Kimball index).
- **Sources:** Ambler (above); Kimball [technique index](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/) (fetched).

### composite-key

- **Situation:** Identity is inherently made of several attributes (junction rows, order lines, tenant-scoped rows), or the store's physical layout depends on the key.
- **Structure:** Multi-column PK. Cases: `(order_id, line_no)` for dependent rows; `(tenant_id, id)` in sharded multi-tenant schemas, where Citus requires "primary and foreign key constraints include the distribution column" and Microsoft says the tenant identifier is "the leading element in the primary key of all sharded tables"; partition keys must be part of every unique key on PostgreSQL, MySQL and SQL Server partitioned tables; SQLite `WITHOUT ROWID` tables cluster rows by a (possibly composite) PK.
- **Trade-offs:** Encodes locality and integrity in the key; wider FKs; ORMs handle composite keys less smoothly.
- **Sources:** Citus, [Multi-tenant Applications](https://docs.citusdata.com/en/stable/use_cases/multi_tenant.html); Microsoft, [Multitenant SaaS patterns](https://learn.microsoft.com/en-us/azure/azure-sql/database/saas-tenancy-app-design-patterns); SQLite, [WITHOUT ROWID](https://www.sqlite.org/withoutrowid.html) (all fetched).

### time-ordered-identifier

- **Situation:** IDs must be generated without coordination (by clients, many services, many shards) yet insert efficiently into B-tree indexes and sort roughly by creation time.
- **Structure:** 128-bit UUIDv7 (48-bit Unix millisecond timestamp, version, 74 random bits) stored as native `uuid`/binary, or ULID (48-bit timestamp + 80 random bits, 26-character Crockford Base32), or 64-bit Snowflake-style IDs (41-bit time with custom epoch, 10-bit machine id, 12-bit sequence).
- **Trade-offs:** RFC 9562: random UUIDv4 has "poor database-index locality"; "Time-ordered monotonic UUIDs benefit from greater database-index locality"; store as binary, not text; treat as opaque; do not use name-based v3/v5 as keys. The timestamp leaks creation time. Snowflake needs machine-id assignment but fits in `bigint`. PostgreSQL 18 ships `uuidv7()` ("temporally sortable") and `uuid_extract_timestamp()`.
- **Names in sources:** UUID Version 7 (RFC 9562 §5.7); ULID (spec); Snowflake (Twitter); "k-sorted" ids (Snowflake README).
- **Sources:** [RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html) §2.1, §5.7, §6.2, §6.11–6.13; [ULID spec](https://github.com/ulid/spec); [twitter-archive/snowflake (2010 branch README)](https://github.com/twitter-archive/snowflake/tree/snowflake-2010); PostgreSQL, [UUID Functions](https://www.postgresql.org/docs/current/functions-uuid.html) (all fetched). **Unverified:** Twitter's "Announcing Snowflake" post (403) and Instagram's "Sharding & IDs at Instagram" (unreachable), the originator of shard-encoding IDs generated in PostgreSQL.

### hi-lo-allocation

- **Situation:** ORMs need IDs before insert (to build object graphs and batch inserts) without one database round trip per row.
- **Structure:** The database hands out blocks; the client allocates values inside a block. Ambler's HIGH-LOW: "A unique HIGH value that you obtain from a defined source and an N-digit LOW value that your application assigns itself." Hibernate's modern form encodes the block size in the sequence's `INCREMENT BY` ("pooled" / "pooled-lo" optimizers).
- **Trade-offs:** Fewer round trips; gaps when blocks are abandoned; every writer must use the same scheme. Hibernate: the classic "hilo; legacy-hilo" optimizers "are not recommended for use", kept for legacy applications. PostgreSQL sequence `CACHE` is the server-side variant (values may be out of order across sessions).
- **Sources:** Ambler, [keys essay](https://agiledata.org/essays/keys.html); Hibernate, [User Guide 6.6](https://docs.hibernate.org/orm/6.6/userguide/html_single/Hibernate_User_Guide.html) §3.7.13 "Optimizers"; PostgreSQL, [CREATE SEQUENCE](https://www.postgresql.org/docs/current/sql-createsequence.html) (all fetched).

### public-identifier

- **Situation:** Internal keys must not be exposed (enumeration, leaking volume, coupling clients to storage), or external IDs must be readable and self-describing.
- **Structure:** A separate unique, opaque external ID column (UUID, or a type-prefixed string such as `cus_…`, `ch_…`) alongside an internal key; Stripe's prefixes also let one parameter accept several object types and make leaked secrets detectable by regex.
- **Trade-offs:** Decouples API from storage; one more unique index. Stripe's official docs treat IDs as opaque: adding or removing prefixes is a backward-compatible change, and IDs can be up to 255 characters, to be stored case-sensitively (`VARCHAR(255) COLLATE utf8_bin`).
- **Names in sources:** object IDs (Stripe); prefixed IDs (Stripe developer blog). Internal/external key split as a general pattern: no primary source found (unverified).
- **Sources:** Stripe, [API versioning: compatible changes](https://docs.stripe.com/api-versions) (fetched); Paul Asjes (Stripe), [Designing APIs for humans: Object IDs](https://dev.to/stripe/designing-apis-for-humans-object-ids-3o5a), 2022 (fetched; vendor-employee blog).

## Relationships

### foreign-key-reference

- **Situation:** The baseline one-to-many relationship.
- **Structure:** FK column on the "many" side referencing the "one" side's key, with an explicit `ON DELETE` action (`NO ACTION`, `RESTRICT`, `CASCADE`, `SET NULL [(cols)]`, `SET DEFAULT`) and an index on the referencing column (PostgreSQL does not create one automatically). Deferrable FKs (checked at commit) handle cycles and bulk reorders.
- **Trade-offs:** Integrity in the database versus write cost; omission is Karwin's "Keyless Entry".
- **Names in sources:** Foreign Key Mapping (Fowler PoEAA); relationship mappings (Ambler).
- **Sources:** Fowler, [Foreign Key Mapping](https://martinfowler.com/eaaCatalog/foreignKeyMapping.html) (catalog fetched); PostgreSQL, [Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html) and [CREATE TABLE](https://www.postgresql.org/docs/current/sql-createtable.html) (fetched).

### association-table

- **Situation:** Many-to-many relationships, or a relationship that carries its own attributes (role, quantity, dates).
- **Structure:** A junction table with two FKs and a composite PK (or a unique constraint) over them; promote it to a full entity when it gains attributes and identity of its own.
- **Trade-offs:** The only relational form of many-to-many; the alternative is Karwin's "Jaywalking" (ID lists in a string) or "Multicolumn Attributes". Karwin's "ID Required" warns against giving it a redundant surrogate `id` that permits duplicate pairs.
- **Names in sources:** Association Table Mapping (Fowler PoEAA); Associative Type (Fowler AP 15.1); associative table, Many-To-Many Mappings (Ambler); intersection table (Karwin); junction/join/link table (common usage); Replace One-To-Many With Associative Tables (Ambler/Sadalage refactoring); has_and_belongs_to_many vs has_many :through (Rails, HABTM needs "a join table without a primary key"; use `:through` when the link needs attributes, validations or callbacks; [Rails association guide](https://guides.rubyonrails.org/association_basics.html), fetched).
- **Sources:** Fowler, [Association Table Mapping](https://martinfowler.com/eaaCatalog/associationTableMapping.html) (catalog fetched); Ambler, [Mapping Objects to Relational Databases](https://agiledata.org/essays/mappingObjects.html) (fetched).

### dependent-and-embedded-mapping

- **Situation:** Parts that have no identity outside their owner (order lines, address value objects).
- **Structure:** Embedded Value: the value object's fields become columns of the owner's table (`billing_street`, `billing_city`); Dependent Mapping: child rows in a separate table whose lifecycle and persistence are owned by the parent (often a composite PK of parent id + line number); Serialized LOB: the whole graph in one column.
- **Trade-offs:** Embedded Value avoids joins but repeats column groups; dependent tables keep 1NF but must be written through the owner.
- **Names in sources:** Embedded Value, Dependent Mapping, Serialized LOB (Fowler PoEAA); composite types (PostgreSQL, unverified as a pattern source).
- **Sources:** Fowler, [Embedded Value](https://martinfowler.com/eaaCatalog/embeddedValue.html), [Dependent Mapping](https://martinfowler.com/eaaCatalog/dependentMapping.html), [Serialized LOB](https://martinfowler.com/eaaCatalog/serializedLOB.html) (catalog fetched).

### one-to-one-split

- **Situation:** An entity with an optional or separately managed part (user and profile, product and inventory counters), or columns with different access, security or change rates.
- **Structure:** A second table whose PK is also an FK to the first (shared primary key), so at most one row per parent.
- **Trade-offs:** See `vertical-partitioning`; the shared-PK form makes the 1:1 a database invariant, while a separate FK with a unique constraint allows the parts to be created independently.
- **Names in sources:** Split Table (Ambler/Sadalage); vertical partitioning (Microsoft); shared primary key (common usage, unverified source).
- **Sources:** [databaserefactoring.com](https://databaserefactoring.com/) (fetched); Microsoft [data partitioning recommendations](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/partition-data) (fetched).

## Hierarchies and graphs

Trees are the area with the richest, best-documented menu of structures. Karwin's comparison and Celko's book cover the same four relational encodings; vendors add native types for two of them (materialized path, adjacency traversal) and, recently, for property graphs. Karwin's comparison table exists in two of his slide decks, [Practical Object-Oriented Models in SQL](https://www.slideshare.net/billkarwin/practical-object-oriented-models-in-sql) (2009) and [Models for Hierarchical Data](https://www.slideshare.net/billkarwin/models-for-hierarchical-data) (2010), both fetched as text extractions. The two extractions agree on most cells but disagree on two: Path Enumeration "Query Child" (Easy in the 2009 extraction, Hard in the 2010 one) and Closure Table "Move Subtree" (Hard in 2009, Easy in 2010). The cell alignment of the extractions is unreliable, so those two cells are unverified until checked against the slide images or the book.

### adjacency-list

- **Situation:** Each node has at most one parent (comment threads, org charts, categories); writes are frequent and subtree reads are rarer or can use recursion.
- **Structure:** One table with `parent_id` referencing the same table's key (nullable for roots). Subtrees are read with `WITH RECURSIVE` (see `recursive-tree-query`).
- **Trade-offs:** Both Karwin decks rate it Easy for child queries and Hard for subtree queries, and it is the only single-table design with referential integrity. Without recursive SQL it degenerates into Karwin's "Naive Trees" anti-pattern (fixed-depth self-joins).
- **Names in sources:** Adjacency List (Karwin, Celko ch. 2); Parent References (MongoDB tree docs); self-referencing relationship; Fowler PoEAA has no separate name (it is a Foreign Key Mapping to the same table).
- **Sources:** Karwin, [Practical Object-Oriented Models in SQL](https://www.slideshare.net/billkarwin/practical-object-oriented-models-in-sql) (slides, fetched; comparison table "Choose the right design"); Celko, [Trees and Hierarchies in SQL for Smarties, 2nd ed.](https://shop.elsevier.com/books/joe-celkos-trees-and-hierarchies-in-sql-for-smarties/celko/978-0-12-387733-8) (publisher TOC fetched: ch. 2 "Adjacency list model").

### recursive-tree-query

- **Situation:** Traverse an adjacency list or a general graph (ancestors, descendants, bill-of-materials explosion) without changing the stored structure.
- **Structure:** `WITH RECURSIVE` = non-recursive anchor term `UNION [ALL]` recursive term. PostgreSQL adds `SEARCH DEPTH FIRST | BREADTH FIRST BY col SET ordercol` and `CYCLE id SET is_cycle USING path`.
- **Trade-offs:** No denormalized data to maintain; cost is paid at read time. PostgreSQL warns the query "will loop if the link relationships contain cycles" and advises against relying on `LIMIT` as a guard. Oracle's `CONNECT BY` and SQL Server's `hierarchyid` are proprietary alternatives Celko catalogs in ch. 9 "Proprietary extensions".
- **Names in sources:** Recursive Queries / recursive CTE (PostgreSQL), hierarchical query (Oracle).
- **Sources:** PostgreSQL, [WITH Queries](https://www.postgresql.org/docs/current/queries-with.html) §7.8 (fetched, v18).

### path-enumeration

- **Situation:** Read-heavy trees where you need ancestors/breadcrumbs and subtree queries by prefix, and moves are rare.
- **Structure:** One column holding the root-to-node path (`1/4/6/7/`), queried with `LIKE 'prefix%'`. Native types: PostgreSQL `ltree` (dot-separated labels, GiST operators `@>`, `<@`, `~`); SQL Server `hierarchyid` (a compact binary path, ~5 bytes per node in a 100k-node org, ordered depth-first).
- **Trade-offs:** Karwin: Easy subtree queries but no referential integrity (the path is a string, not FKs); his decks disagree on immediate-child queries (see above), which are indeed awkward because they need a depth predicate; moving a subtree rewrites all descendant paths. `ltree` limits: labels up to 1000 characters, paths up to 65535 labels. Microsoft says a `hierarchyid` column "doesn't automatically represent a tree", uniqueness is not guaranteed and relationships "aren't enforced like a foreign key"; it shows enforcing the tree with a persisted computed `GetAncestor(1)` column plus an FK, i.e. a hybrid of path enumeration and adjacency list.
- **Names in sources:** Path Enumeration (Karwin; Celko ch. 3 "Path enumeration models"); Materialized Paths (MongoDB tree docs); label path (PostgreSQL `ltree`); lineage column (common usage, unverified).
- **Sources:** Karwin slides (above); Celko TOC (above); PostgreSQL, [ltree](https://www.postgresql.org/docs/current/ltree.html) (fetched); Microsoft, [Hierarchical data (SQL Server)](https://learn.microsoft.com/en-us/sql/relational-databases/hierarchical-data-sql-server) (fetched).

### nested-sets

- **Situation:** Mostly static hierarchies (catalog taxonomies, published reports) where subtree reads and aggregation dominate.
- **Structure:** Each node stores `lft`/`rgt` integers from a depth-first walk; descendants satisfy `child.lft BETWEEN parent.lft AND parent.rgt`.
- **Trade-offs:** Both Karwin decks rate subtree query Easy but child query, insert, delete and move Hard, with no referential integrity. Any insert renumbers on average half the tree. Celko devotes a chapter to "Frequent insertion trees" (spread/gaps, rational numbers) as mitigation.
- **Names in sources:** Nested Sets (Karwin; Celko ch. 4 "Nested set model"); MongoDB docs also list "Nested Sets" as a tree model; modified preorder tree traversal (MPTT, common usage, unverified origin).
- **Sources:** Karwin slides; Celko TOC (above).

### nested-intervals

- **Situation:** Same reads as nested sets but without global renumbering on insert.
- **Structure:** Nodes are encoded as rational intervals (Farey fractions or continued fractions) so new children always fit; the encoding relates to the materialized path.
- **Trade-offs:** Avoids reorganization; arithmetic encoding is opaque and rarely supported by tooling. Mostly of academic interest.
- **Names in sources:** Nested Intervals (Tropashko); Celko ch. 5 covers rational-number variants.
- **Sources:** Vadim Tropashko, [Nested Intervals Tree Encoding with Continued Fractions](https://arxiv.org/abs/cs/0402051), arXiv 2004 (abstract fetched); "Nested intervals tree encoding in SQL", SIGMOD Record 34(2), 2005 (not fetched).

### closure-table

- **Situation:** Trees (or DAGs) where both subtree and ancestor queries must be fast and referential integrity matters.
- **Structure:** Node table unchanged, plus `tree_paths(ancestor, descendant[, depth])` with one row for every ancestor/descendant pair including each node to itself; both columns are FKs.
- **Trade-offs:** Both Karwin decks rate child and subtree queries Easy with referential integrity; they disagree on Move Subtree (see above), which in practice requires deleting and reinserting the moved subtree's ancestor rows. Storage "requires O(n²) rows" in the worst case "(but far fewer in practice)"; an optional `length` column "Makes it easier to query immediate parent or child" (2010 deck). Works for multiple parents (DAG) where nested sets and path enumeration do not.
- **Names in sources:** Closure Table (Karwin); transitive closure table; ancestor table (Celko discusses transitive-closure approaches in ch. 8 "Other models", unverified detail).
- **Sources:** Karwin, both slide decks (above); Karwin, [SQL Antipatterns Vol. 1](https://pragprog.com/titles/bksap1/sql-antipatterns-volume-1/), chapter "Naive Trees" (TOC fetched; solution names from slides).

### graph-tables

- **Situation:** General many-to-many networks (social graphs, dependencies, fraud rings) queried by path patterns.
- **Structure:** Node tables plus edge tables `(from_id, to_id, edge attributes)`; native variants: SQL Server SQL Graph node/edge tables with `MATCH`; ISO SQL/PGQ (`CREATE PROPERTY GRAPH` over ordinary tables, `GRAPH_TABLE ... MATCH`).
- **Trade-offs:** Plain edge tables keep full relational integrity and use recursive CTEs for traversal; SQL/PGQ adds declarative pattern matching without moving data. Microsoft (SQL Graph, SQL Server 2017+): "A relational database can achieve anything a graph database can", graph syntax just makes some queries easier; edge constraints restrict which node tables an edge may connect; `hierarchyid` "doesn't allow you to store multiple parents for a node", which is when to switch to edges.
- **Names in sources:** edge table / node table (SQL Server); SQL-property graph (ISO/IEC 9075-16); Celko ch. 12 "General graphs".
- **Sources:** Microsoft, [SQL Graph overview](https://learn.microsoft.com/en-us/sql/relational-databases/graphs/sql-graph-overview) (fetched); [ISO/IEC 9075-16:2023 SQL/PGQ](https://www.iso.org/standard/79473.html) (standard record; fetch returned 403, identity confirmed through search; full text paywalled, not read); Celko TOC (above); DynamoDB's "adjacency list" and "materialized graph" patterns are the key-value equivalents (see document section).

## Inheritance and polymorphism

Fowler's three PoEAA mappings are the canonical names; Ambler's essay names the same three plus a fourth generic one, and every major ORM ships the three under its own names. Karwin offers the same three as the cure for EAV.

### single-table-inheritance

- **Situation:** A type hierarchy whose subtypes share most attributes and are often queried together (payments: card, transfer, wallet).
- **Structure:** One table with the union of all subtypes' columns and a discriminator column (`type`); subtype-specific columns are nullable, ideally guarded by `CHECK ((type = 'card') = (card_last4 IS NOT NULL))`-style constraints.
- **Trade-offs:** Fowler: avoids the joins that "can quickly mount up" with multi-table mappings; costs NOT NULL enforcement for subtype columns, wasted space, and one table that every subtype change touches. Document stores' Polymorphic and Inheritance patterns are the same idea.
- **Names in sources:** Single Table Inheritance (Fowler PoEAA); Map Hierarchy To A Single Table (Ambler); Single Table Inheritance with a `type` column (Rails); `SINGLE_TABLE` with `DTYPE` discriminator, the JPA default (Hibernate); proxy models share the parent table but add no columns (Django). Hibernate: "it's not possible to use NOT NULL constraints anymore, so integrity checks must be moved either into the data access layer or enforced through CHECK or TRIGGER constraints".
- **Sources:** Fowler, [Single Table Inheritance](https://martinfowler.com/eaaCatalog/singleTableInheritance.html) (fetched); Ambler, [Mapping Objects to Relational Databases](https://agiledata.org/essays/mappingObjects.html) (fetched); Karwin slides (EAV alternatives, fetched); Rails, [association guide](https://guides.rubyonrails.org/association_basics.html); Hibernate, [User Guide 6.6](https://docs.hibernate.org/orm/6.6/userguide/html_single/Hibernate_User_Guide.html) §3.14; Django, [model inheritance](https://docs.djangoproject.com/en/5.2/topics/db/models/) (all fetched).

### class-table-inheritance

- **Situation:** Subtypes with substantial distinct attributes that must be NOT NULL and constrained, plus queries over the supertype.
- **Structure:** A table for the supertype and one per subtype; the subtype PK is also an FK to the supertype PK (shared key).
- **Trade-offs:** Full constraints per subtype and a single key space; joins to load a complete object; nothing in plain SQL stops a supertype row from having zero or two subtype rows (a discriminator plus composite FK `(id, type)` can enforce it, unverified as a sourced technique). Karwin's "Base parent table" fix for polymorphic associations is this structure.
- **Names in sources:** Class Table Inheritance (Fowler); Map Each Class To Its Own Table (Ambler); `JOINED` "table-per-subclass" (Hibernate: "polymorphic queries can use several JOINS"); multi-table inheritance with an auto-created one-to-one parent link such as `place_ptr` (Django); Delegated Types (Rails, "an alternative to single-table inheritance" since 6.1; the superclass is "a concrete class that is represented by its own table" with `entryable_type`/`entryable_id`, each subclass table holding only its own attributes; [DelegatedType API](https://api.rubyonrails.org/classes/ActiveRecord/DelegatedType.html), [6.1 release notes](https://guides.rubyonrails.org/6_1_release_notes.html), fetched); supertype and subtype schemas (Kimball).
- **Sources:** Fowler, [Class Table Inheritance](https://martinfowler.com/eaaCatalog/classTableInheritance.html) (catalog fetched); Ambler (above).

### concrete-table-inheritance

- **Situation:** Subtypes rarely queried together, each with its own lifecycle.
- **Structure:** One table per concrete class carrying both inherited and own columns; no supertype table.
- **Trade-offs:** No joins and no nullable subtype columns; queries over the supertype need `UNION ALL`; IDs must be unique across tables if anything references "any subtype"; FKs to the abstract type are impossible.
- **Names in sources:** Concrete Table Inheritance (Fowler); Map Each Concrete Class To Its Own Table (Ambler); `TABLE_PER_CLASS` "table-per-concrete-class", "Polymorphic queries require multiple UNION queries" (Hibernate §3.14.4); abstract base classes copy fields into each child table (Django); `@MappedSuperclass` keeps inheritance "visible in the domain model only" (Hibernate).
- **Sources:** Fowler, [Concrete Table Inheritance](https://martinfowler.com/eaaCatalog/concreteTableInheritance.html) (catalog fetched); Ambler (above).

### generic-table-structure

- **Situation:** Classes defined at run time.
- **Structure:** Ambler's "Map Classes To A Generic Table Structure", a meta-data driven approach storing class, attribute and value rows; structurally EAV.
- **Sources:** Ambler (above). See `entity-attribute-value`.

### postgresql-table-inheritance

- **Situation:** PostgreSQL-specific: a child table automatically includes the parent's columns and parent queries include child rows.
- **Structure:** `CREATE TABLE capitals (...) INHERITS (cities)`.
- **Trade-offs:** PostgreSQL itself flags "A serious limitation": "indexes (including unique constraints) and foreign key constraints only apply to single tables, not to their inheritance children", on both sides of an FK. Its main historical use, partitioning, is superseded by declarative partitioning. Weak chapter candidate; better as a cautionary variant inside `class-table-inheritance`.
- **Sources:** PostgreSQL, [Inheritance](https://www.postgresql.org/docs/current/ddl-inherit.html) (fetched).

### polymorphic-association

- **Situation:** One kind of child (comment, attachment, tag) belongs to parents of several types.
- **Structure:** `(commentable_type, commentable_id)` pair; no FK can be declared.
- **Trade-offs:** Convenient and supported by ORMs; the database cannot enforce existence or delete-cascade; Karwin's anti-pattern chapter. Alternatives, in Karwin's words: "Exclusive Arcs", "Reverse the relationship" (one association table per parent type), "Base parent table".
- **Names in sources:** Polymorphic Associations (Karwin, Rails); `belongs_to :imageable, polymorphic: true` with `imageable_type` + `imageable_id` and a composite index (Rails); `GenericForeignKey(content_type, object_id)` (Django contenttypes: no index created automatically, unusable in `filter()`, no `on_delete`, dangling values on target deletion)
- **Sources:** Karwin slides (fetched); [Rails association guide](https://guides.rubyonrails.org/association_basics.html); Django, [contenttypes framework](https://docs.djangoproject.com/en/5.2/ref/contrib/contenttypes/) (fetched).

### exclusive-arc

- **Situation:** A child references exactly one of a small, fixed set of parent types, with real FKs.
- **Structure:** One nullable FK column per parent type plus `CHECK (num_nonnulls(post_id, photo_id, video_id) = 1)`.
- **Trade-offs:** Real referential integrity and cascades; adding a parent type is DDL; Karwin's slide: "hard to ensure exactly one is non-null" (a CHECK solves it on engines with such functions).
- **Names in sources:** Exclusive Arcs (Karwin); exclusive arc / mutually exclusive relationships (Barker's CASE*Method ER notation, adopted in Oracle Designer; the book was not read, so the origin is unverified).
- **Sources:** Karwin slides (fetched).

### shared-supertype

- **Situation:** Several entity types must be referenceable uniformly (anything can be commented on, tagged or owned), with FKs.
- **Structure:** A common super-table (`commentable(id)`) whose key every parent type shares (class-table inheritance); children reference the super-table.
- **Names in sources:** Base parent table / common super-table (Karwin); Party (Silverston, Fowler AP) is the domain-specific case; Delegated Types (Rails) is the ORM form.
- **Sources:** Karwin slides (fetched); see `party-model` and `class-table-inheritance`.

## Flexible and variable attributes

The forces are the same in every source: attributes that vary per row, are numerous and sparse, or must be added without DDL. Fowler's "Dealing with Properties" (see classic catalogs, `dynamic-property`) gives the finest-grained taxonomy; vendors now steer toward a hybrid of real columns for what is queried and a document column for the rest.

### entity-attribute-value

- **Situation:** Open-ended, user-defined attributes (product specs per category, clinical observations, CMS custom fields) whose set is unknown at design time.
- **Structure:** `entity(id, …)`, `attribute(id, name, data_type, …)`, `value(entity_id, attribute_id, value)`; typed variants keep one value column per data type, or typed sparse columns. Fowler's variants: Flexible Dynamic Property (attribute named by a string), Defined Dynamic Property (attribute row), Typed Dynamic Property (attribute declares its type), Dynamic Property Knowledge Level (which entity types may have which attributes).
- **Trade-offs:** Schema-free extension versus loss of types, NOT NULL, FKs and CHECK constraints on values, and one join per attribute to rebuild a row. MariaDB's knowledge-base article calls the naive design a "Bad solution" ("multiple JOINs"; "Numbers stored in VARCHAR do not compare 'correctly'") and recommends real columns for the frequently searched fields plus a JSON blob for the rest. Karwin lists it as an anti-pattern (see anti-patterns).
- **Names in sources:** Entity-Attribute-Value, EAV (Karwin, MariaDB, Microsoft); name/value pairs (Microsoft archive blog); Dynamic Property family (Fowler); Attribute Pattern is the document-store form (MongoDB); "open schema" (common usage, unverified).
- **Sources:** Fowler, [Dealing with Properties](https://martinfowler.com/apsupp/properties.pdf) (fetched); MariaDB, [Entity-Attribute-Value Implementation](https://mariadb.com/docs/server-1/ha-and-performance/optimization-and-tuning/optimizing-tables/entity-attribute-value-implementation) (article by Rick James, fetched); Microsoft archive blog, [A conversation about how to implement name/value pairs](https://learn.microsoft.com/en-us/archive/blogs/qingsongyao/a-conversation-about-how-to-implement-namevalue-pairs), 2009 (fetched; suggests sparse columns + column sets as replacement).

### json-column

- **Situation:** Semi-structured or rarely queried attributes next to a relational core; payloads received from external APIs; per-tenant custom fields.
- **Structure:** A `jsonb` (PostgreSQL) / `JSON` (MySQL) / text-JSON (SQLite) column beside ordinary columns; index paths with GIN (`jsonb_ops`, `jsonb_path_ops`) in PostgreSQL, or with indexed generated columns and multi-valued indexes (8.0.17+) in MySQL.
- **Trade-offs:** PostgreSQL: JSON "can be considerably more flexible than the traditional relational data model… It is quite possible for both approaches to co-exist", but "it is still recommended that JSON documents have a somewhat fixed structure"; any update locks the whole row, so keep documents small and each "an atomic datum that business rules dictate cannot reasonably be further subdivided". MySQL: JSON columns are "not indexed directly; instead… index on a generated column". SQLite stores JSON as text (JSONB blobs since 3.45.0). Microsoft's WideWorldImporters sample uses a JSON `CustomFields` column, which the team describes as looking "like EAV model where key-values are not stored in separate table".
- **Names in sources:** JSON types (PostgreSQL, MySQL); Serialized LOB (Fowler PoEAA, the general pattern: serialize an object graph into one large column); hybrid model; "inheritance with JSON" (Microsoft).
- **Sources:** PostgreSQL, [JSON Types](https://www.postgresql.org/docs/current/datatype-json.html) §8.14 "Designing JSON Documents" (fetched); MySQL 8.4, [The JSON Data Type](https://dev.mysql.com/doc/refman/8.4/en/json.html), [CREATE INDEX (multi-valued indexes)](https://dev.mysql.com/doc/refman/8.4/en/create-index.html) (fetched); SQLite, [JSON functions](https://www.sqlite.org/json1.html) (fetched); Microsoft archive blog, [Inheritance with JSON](https://learn.microsoft.com/en-us/archive/blogs/sqlserverstorageengine/inheritance-with-json), 2016 (fetched); Fowler, [Serialized LOB](https://martinfowler.com/eaaCatalog/serializedLOB.html) (catalog fetched).

### sparse-columns

- **Situation:** Many optional, mostly-NULL typed attributes (SharePoint-style user-defined properties) where EAV is too slow and a wide table too costly.
- **Structure:** SQL Server `SPARSE` columns (NULL takes no space) plus an optional `XML COLUMN_SET FOR ALL_SPARSE_COLUMNS` that exposes them all as one updatable XML value; filtered indexes on the few searched columns.
- **Trade-offs:** Microsoft: use them "when the space saved is at least 20 percent to 40 percent"; non-NULL values cost more (sparse `int` takes 8 bytes instead of 4). Must be nullable; no defaults; not in the clustered index or PK; incompatible with data compression; a column set changes `SELECT *` and cannot be indexed.
- **Sources:** Microsoft, [Use sparse columns](https://learn.microsoft.com/en-us/sql/relational-databases/tables/use-sparse-columns) and [Use column sets](https://learn.microsoft.com/en-us/sql/relational-databases/tables/use-column-sets) (fetched).

### key-value-column

- **Situation:** Flat string key/value tags per row (labels, metadata) with containment queries.
- **Structure:** PostgreSQL `hstore` column, indexed with GiST or GIN for `@>`, `?`, `?&`, `?|`.
- **Trade-offs:** PostgreSQL: "useful… rows with many attributes that are rarely examined, or semi-structured data. Keys and values are simply text strings." Largely superseded by `jsonb`, which supports nesting and types.
- **Sources:** PostgreSQL, [hstore](https://www.postgresql.org/docs/current/hstore.html) (fetched).

### generated-column

- **Situation:** A value derived from other columns of the same row that must be indexed, constrained or queried without duplicating logic (extracting a JSON field, normalizing case, computing totals).
- **Structure:** `GENERATED ALWAYS AS (expr) STORED | VIRTUAL`. PostgreSQL 18 added virtual generated columns and made them the default; MySQL defaults to VIRTUAL and indexes virtual columns in InnoDB.
- **Trade-offs:** No drift between source and derived value; PostgreSQL restricts expressions to immutable functions over the current row, forbids referencing other generated columns, and does not allow generated columns in a partition key.
- **Sources:** PostgreSQL, [Generated Columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html) and [Release 18](https://www.postgresql.org/docs/release/18.0/) (fetched); MySQL, [Generated Columns](https://dev.mysql.com/doc/refman/8.4/en/create-table-generated-columns.html) (fetched).

## Reference data and constrained values

The same question — where does the list of allowed values live — has four structural answers with sharply different change costs. Karwin's "31 Flavors" and the OTLT critique (see anti-patterns) bracket the space.

### lookup-table

- **Situation:** A column takes values from a list that business users may extend, or whose values carry attributes (label, sort order, active flag, translations).
- **Structure:** One small table per domain (`order_status(code PK, label, sort_order, is_active)`) and an FK from the using table. Retire values with an `is_active` flag rather than delete them so history stays valid.
- **Trade-offs:** Changes are DML, values are queryable and can carry attributes; costs a join (or a natural code key that avoids it). Celko recommends a separate table per attribute; Karwin presents it as the fix for "31 Flavors". Distributed systems replicate such tables to every shard (Citus "reference table"; Azure guidance "replicate static reference data").
- **Names in sources:** look-up table (Celko); lookup table / reference table (Karwin; Citus); code table.
- **Sources:** Celko, [Look-up Tables in SQL](https://www.red-gate.com/simple-talk/databases/sql-server/t-sql-programming-sql-server/look-up-tables-in-sql/) (fetched); Karwin "31 Flavors" (TOC fetched); Citus, [Concepts](https://docs.citusdata.com/en/stable/get_started/concepts.html) (fetched); Microsoft, [Data partitioning recommendations](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/partition-data) (fetched).

### enum-type

- **Situation:** A small, stable, ordered set of values owned by developers, where a join is unwanted.
- **Structure:** A database enum type (PostgreSQL `CREATE TYPE ... AS ENUM`, MySQL inline `ENUM`).
- **Trade-offs:** PostgreSQL: "a static, ordered set of values", 4 bytes per value; "Existing values cannot be removed from an enum type, nor can the sort ordering of such values be changed, short of dropping and re-creating the enum type"; a value added inside a transaction cannot be used until it commits. Karwin classifies inline enums as the "31 Flavors" anti-pattern.
- **Sources:** PostgreSQL, [Enumerated Types](https://www.postgresql.org/docs/current/datatype-enum.html) and [ALTER TYPE](https://www.postgresql.org/docs/current/sql-altertype.html) (fetched).

### check-constraint-domain

- **Situation:** Value rules that are row-local and stable (positive amounts, a short code list, format rules), reused across many columns.
- **Structure:** `CHECK` constraints on columns; a `DOMAIN` (PostgreSQL, SQL standard) packaging a base type plus constraints for reuse.
- **Trade-offs:** PostgreSQL assumes CHECK conditions are immutable and does not support CHECK constraints referencing other rows or tables ("use UNIQUE, EXCLUDE, or FOREIGN KEY constraints to express cross-row and cross-table restrictions"). Domain NOT NULL can be bypassed through outer joins; the docs advise allowing NULL in the domain and putting NOT NULL on the column. PostgreSQL 18 adds `NOT ENFORCED` CHECK and FK constraints.
- **Sources:** PostgreSQL, [Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html), [CREATE DOMAIN](https://www.postgresql.org/docs/current/sql-createdomain.html), [Release 18](https://www.postgresql.org/docs/release/18.0/) (fetched).

### status-history

- **Situation:** An entity moves through a lifecycle (order: placed → paid → shipped) and you need both the current state and when each transition happened, plus the rule of which transitions are legal.
- **Structure:** Current `status` column (FK to a lookup table) plus an append-only `entity_status_history(entity_id, status, changed_at, actor)`; optionally a `status_transition(from_status, to_status)` table referenced by a composite FK so illegal transitions are rejected by the database.
- **Trade-offs:** Status history is queryable and auditable; the transition table moves part of a state machine into data. Analytics models the same lifecycle as an accumulating snapshot fact (one row per order, one date column per milestone).
- **Names in sources:** Order status, Invoice status, Status Types (Silverston Vol. 1 Figs. 4.7, 7.4; party relationship status types); Subtype State Machines (Fowler AP 10.4); Accumulating snapshot (Kimball, see analytics). The transition-table FK technique has no primary source located (unverified).
- **Sources:** Silverston model list (fetched); Fowler AP TOC (fetched).

## Time, history and deletion

Two clocks run through every source. Fowler calls them actual time and record time; SQL:2011 calls them application time and system time; the temporal-database literature calls them valid time and transaction time ([Bitemporal History](https://martinfowler.com/articles/bitemporal-history.html), fetched, makes the equivalence explicit). Fowler's [Temporal Patterns](https://martinfowler.com/eaaDev/timeNarrative.html) page (fetched) lists Audit Log, Time Point, Effectivity, Temporal Property, Temporal Object and Snapshot. The SQL:2011 primary paper is Kulkarni and Michels, [Temporal features in SQL:2011](https://sigmodrecord.org/2012/09/30/temporal-features-in-sql2011/), SIGMOD Record 41(3), 2012 (PDF fetched and read): periods are metadata over a pair of columns with closed-open semantics, at most one application-time and one system-time period per table, and "A table may be both a system-versioned table and an application-time period table".

### soft-delete

- **Situation:** Deletions must be reversible, auditable or deferred (user "trash", legal retention, references from history that must not dangle).
- **Structure:** A `deleted_at` timestamp (or boolean flag) on the row; every query filters on it, usually through an ORM default scope; uniqueness and partial indexes must be restricted to live rows (`UNIQUE … WHERE deleted_at IS NULL`).
- **Trade-offs:** Laravel: soft-deleted models "will automatically be excluded from all query results"; Hibernate 6.4+ `@SoftDelete` with ACTIVE/DELETED strategies (7.0 adds TIMESTAMP). The Rails `discard` gem deliberately avoids default scopes ("It's usually undesirable to add a default scope") and lists how paranoia-style scopes leak (`.with_deleted`, overridden `destroy`, cascades). Brandur Leach (opinion) argues it "probably isn't worth it": the filter leaks into every query, FKs stop protecting anything, hard pruning is hard, and undelete is almost never used; he proposes a `deleted_record(id, deleted_at, original_table, original_id, data jsonb)` archive table filled by `DELETE … RETURNING`. Ambler and Sadalage list both "Introduce Soft Delete" and "Introduce Hard Delete" refactorings.
- **Names in sources:** Soft Deleting (Laravel), `@SoftDelete` (Hibernate), discard / kept (Rails gem), Introduce Soft Delete (Ambler/Sadalage); logical delete, tombstone (common usage).
- **Sources:** Laravel, [Eloquent: Soft Deleting](https://laravel.com/docs/12.x/eloquent#soft-deleting); Hibernate, [User Guide 6.6](https://docs.hibernate.org/orm/6.6/userguide/html_single/Hibernate_User_Guide.html) §3.12 and [7.0](https://docs.hibernate.org/orm/7.0/userguide/html_single/Hibernate_User_Guide.html); [discard README](https://github.com/jhawthorn/discard); Brandur Leach, [Soft Deletion Probably Isn't Worth It](https://brandur.org/soft-deletion), 2022 (blog, opinion; originator of the archive-table alternative as written); [databaserefactoring.com](https://databaserefactoring.com/) (all fetched).

### audit-log

- **Situation:** You need to know who changed what and when, for compliance or debugging, without changing how the application reads current data.
- **Structure:** A separate append-only table `(table_name, row_id, op, changed_at, actor, old_values, new_values)` written by triggers or application code; generic JSON payloads or one shadow table per audited table.
- **Trade-offs:** Fowler: "A simple log of changes, intended to be easily written and non-intrusive"; easy to write, awkward to query for past states (contrast `history-table`). Ambler's catalog has "Introduce Trigger for History".
- **Names in sources:** Audit Log (Fowler); audit trail; shadow table (common usage, unverified); Introduce Trigger for History (Ambler/Sadalage).
- **Sources:** Fowler, [Audit Log](https://martinfowler.com/eaaDev/AuditLog.html) (fetched); [databaserefactoring.com](https://databaserefactoring.com/) (fetched).

### history-table

- **Situation:** Queries must reconstruct a row as of a past moment ("what was the price on 1 March"), and current-state queries must stay fast.
- **Structure:** Current table plus a history table with the same columns and `valid_from/valid_to` (system time), filled on every update/delete; current table holds open-ended rows. Implemented by hand with triggers, or natively as `system-versioned-table`.
- **Trade-offs:** Point-in-time queries become simple range predicates; doubles write cost and needs a retention policy. Fowler models the object-level view as Temporal Object ("An object that changes over time", a continuity object delegating to versions) and Temporal Property ("A property that changes over time").
- **Sources:** Fowler, [Temporal Object](https://martinfowler.com/eaaDev/TemporalObject.html), [Temporal Property](https://martinfowler.com/eaaDev/TemporalProperty.html) (fetched).

### system-versioned-table

- **Situation:** Transaction-time history that the database maintains and the application cannot falsify.
- **Structure:** SQL:2011 `PERIOD FOR SYSTEM_TIME (row_start, row_end)` with `WITH SYSTEM VERSIONING`; queries with `FOR SYSTEM_TIME AS OF | FROM … TO | BETWEEN … AND`; constraints apply to current rows only. Vendor forms:
  - SQL Server 2016+: current table + history table, two `datetime2` period columns in UTC; `FOR SYSTEM_TIME` adds `CONTAINED IN` and `ALL`. History table cannot have a PK or constraints; no `TRUNCATE`; partitioning and indexes are not copied to history.
  - MariaDB: `WITH SYSTEM VERSIONING`, invisible `ROW_START/ROW_END`, `PARTITION BY SYSTEM_TIME` to keep history in separate partitions, `DELETE HISTORY` privilege, per-column `WITHOUT VERSIONING`.
  - IBM Db2: "system-period temporal table" with a required separate history table linked by `ADD VERSIONING USE HISTORY TABLE`.
  - Oracle: Flashback Time Travel (formerly Flashback Data Archive), history in internal tables with a retention period, restricted DDL.
  - PostgreSQL: this pass did not look for native system versioning in the v18 manual; the PostgreSQL 18 release-note items reviewed cover application-time keys (`WITHOUT OVERLAPS`, `PERIOD`), not system time. Hand-built triggers or extensions are the usual route (unverified which extension to recommend).
- **Trade-offs:** Zero application code and tamper-resistance; schema changes on versioned tables are restricted on every engine; history grows forever unless partitioned or retained.
- **Sources:** Kulkarni & Michels (above); Microsoft, [Temporal tables](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables) and [considerations and limitations](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-table-considerations-and-limitations); MariaDB, [System-versioned tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables); IBM, [System-period temporal tables](https://www.ibm.com/docs/en/db2/11.5.x?topic=tables-system-period-temporal); Oracle, [Using Flashback Technology](https://docs.oracle.com/en/database/oracle/oracle-database/21/adfns/flashback.html) (all fetched).

### effective-dating

- **Situation:** Business validity periods: a price, contract, assignment or address is valid from one date to another, possibly in the future, and periods for the same key must not overlap.
- **Structure:** `valid_from`, `valid_to` columns (or a range type) plus a no-overlap constraint per key. SQL:2011: `PERIOD FOR business_time (start, end)`, `PRIMARY KEY (id, business_time WITHOUT OVERLAPS)`, `UPDATE/DELETE … FOR PORTION OF` (splits rows), temporal FKs `FOREIGN KEY (x, PERIOD p) REFERENCES …` satisfied when the parent rows cover the child period. Vendor forms:
  - PostgreSQL: range types + exclusion constraints (`EXCLUDE USING GIST (room WITH =, during WITH &&)` with `btree_gist`); since 18, `PRIMARY KEY/UNIQUE (id, valid_at WITHOUT OVERLAPS)` and `FOREIGN KEY (…, PERIOD valid_at)`, with btree_gist "the expected way to use this feature" and no referential actions on temporal FKs.
  - MariaDB: application-time periods with `FOR PORTION OF` and `WITHOUT OVERLAPS` (PK/unique; temporal FKs not mentioned).
  - Db2: application-period temporal table (`BUSINESS_TIME`), rows split on point-in-time updates.
  - Oracle: Temporal Validity (`PERIOD FOR user_valid_time`, `AS OF PERIOD FOR`), and the older Workspace Manager valid-time support.
- **Trade-offs:** Without a database-enforced no-overlap rule, effective-dated tables silently accumulate overlaps and gaps; with it, updates become period arithmetic. Fowler's pattern is the minimal form: "Add a time period to an object to show when it is effective."
- **Names in sources:** Effectivity (Fowler); application-time period table (SQL:2011, MariaDB); application-period temporal table (Db2); Temporal Validity (Oracle); valid time; Historic Mapping (Fowler AP); Range (Fowler).
- **Sources:** Fowler, [Effectivity](https://martinfowler.com/eaaDev/Effectivity.html), [Range](https://martinfowler.com/eaaDev/Range.html) (fetched); Kulkarni & Michels (above); PostgreSQL, [Range Types](https://www.postgresql.org/docs/current/rangetypes.html), [btree_gist](https://www.postgresql.org/docs/current/btree-gist.html), [CREATE TABLE](https://www.postgresql.org/docs/current/sql-createtable.html), [Release 18](https://www.postgresql.org/docs/release/18.0/); MariaDB, [Application-time periods](https://mariadb.com/kb/en/application-time-periods/); IBM, [Application-period temporal tables](https://www.ibm.com/docs/en/db2/11.5.x?topic=tables-application-period-temporal); Oracle, [Design basics: Temporal Validity](https://docs.oracle.com/en/database/oracle/oracle-database/21/adfns/design_basics.html), [Workspace Manager valid time](https://docs.oracle.com/en/database/oracle/oracle-database/26/adwsm/valid-time-support-introduction-and-example.html) (all fetched).

### bitemporal-table

- **Situation:** You must answer "what did we believe on date R about the state on date A" (retroactive corrections in insurance, payroll, finance, regulatory reporting).
- **Structure:** Both an application-time period and a system-time period on the same table. Native: MariaDB bitemporal tables, Db2 bitemporal tables, SQL:2011 §2.4; hand-built: four timestamp columns plus history.
- **Trade-offs:** Fowler: record history "captures how our knowledge of history changes"; the cost is query complexity (two time predicates everywhere) and very careful update semantics. Fowler's older Dual Time Record (AP 3.8) is the analysis-pattern ancestor.
- **Sources:** Fowler, [Bitemporal History](https://martinfowler.com/articles/bitemporal-history.html), 2021 (fetched); MariaDB, [Bitemporal tables](https://mariadb.com/kb/en/bitemporal-tables/); IBM Db2 docs (above); Kulkarni & Michels (above) (all fetched).

### snapshot-table

- **Situation:** Periodic state capture (daily balances, month-end inventory) for reporting or fast reconstruction.
- **Structure:** `entity_snapshot(entity_id, as_of, …state)`; in warehouses, a periodic snapshot fact table; in event-sourced systems, snapshots speed up replay.
- **Names in sources:** Snapshot ("A view of an object at a point in time", Fowler); Periodic snapshot fact table (Kimball); "snapshot plus delta" (Cosmos DB modeling docs).
- **Sources:** Fowler, [Snapshot](https://martinfowler.com/eaaDev/Snapshot.html) (fetched); Kimball periodic snapshot page (see analytics).

### event-sourcing

- **Situation:** The history of changes is itself the business record (ledgers, workflows, collaboration), or several read shapes must be derived from one write log.
- **Structure:** Append-only `events(stream_id, version, type, payload, recorded_at)` with `UNIQUE (stream_id, version)` for optimistic concurrency; current state is a projection rebuilt by replay; snapshots bound replay cost.
- **Trade-offs:** Fowler: "Capture all changes to an application state as a sequence of events"; either the log or the state can be the system of record. Costs: event schema evolution, projection rebuilds, eventual consistency of read models, and difficulty deleting personal data.
- **Names in sources:** Event Sourcing (Fowler 2005; Microsoft Azure pattern "Use an append-only store to record a full series of events"; microservices.io), Retroactive Event, Parallel Model (Fowler eaaDev).
- **Sources:** Fowler, [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html) (fetched); Microsoft, [Event Sourcing pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing) (listed in the fetched catalog index); Chris Richardson, [Event sourcing](https://microservices.io/patterns/data/event-sourcing.html) (fetched; drawback: the event store is hard to query and typically needs CQRS).

### append-only-ledger-table

- **Situation:** Records that must be provably untampered (financial postings, audit evidence) inside an ordinary relational database.
- **Structure:** SQL Server 2022 / Azure SQL ledger tables: "Updatable ledger tables" are system-versioned with four extra generated columns; "Append-only ledger tables" block updates and deletes and add two columns; a SHA-256 Merkle-tree digest is stored outside the database.
- **Trade-offs:** Tamper-evidence, not tamper-proofing; existing tables cannot be converted in place; ledger cannot be turned off; history cannot be deleted; dropped columns and tables are renamed and kept.
- **Sources:** Microsoft, [Ledger overview](https://learn.microsoft.com/en-us/sql/relational-databases/security/ledger/ledger-overview) and [Ledger limitations](https://learn.microsoft.com/en-us/sql/relational-databases/security/ledger/ledger-limits) (fetched). Generic form: an insert-only table with revoked UPDATE/DELETE privileges (unverified as a named pattern).

## Money, ledgers and reliable side effects

### double-entry-ledger

- **Situation:** Money (or any conserved quantity: inventory, credits, points) moves between holders and every movement must balance and stay auditable.
- **Structure:** `account(id, type/normal balance, currency)`; `transaction(id, effective_at, status)`; `entry(transaction_id, account_id, amount, direction)` with the invariant that each transaction's entries sum to zero (or debits = credits). Entries are immutable; errors are fixed by new entries. Variants:
  - Fowler: Account ("Collect together related accounting entries and provide summarizing behavior"), Accounting Entry ("An allocation of a sum of money"), Accounting Transaction ("Link two (or more) entries together so that the total of all entries in a transaction is zero"); corrections by Replacement, Reversal or Difference Adjustment, of which only replacement loses history.
  - Square Books: books, journal entries ("must balance to 0") and append-only book entries with a per-book version; signed amounts instead of debit/credit.
  - Modern Treasury: Ledger Transaction (pending/posted/archived, immutable once posted) with Ledger Entries (amount, direction, account) where credits equal debits.
  - TigerBeetle: accounts and transfers, both immutable; two-phase pending transfers; integer amounts with an asset scale.
- **Trade-offs:** Correctness and audit by construction; more rows and the need to choose how balances are derived (see `derived-balance`). Silverston models it as accounting transactions and transaction details (Vol. 1 ch. 8); Hay ch. 7 "Accounting: Basic Bookkeeping".
- **Sources:** Fowler, [Patterns for Accounting](https://martinfowler.com/eaaDev/AccountingNarrative.html), [Account](https://martinfowler.com/eaaDev/Account.html), [Accounting Entry](https://martinfowler.com/eaaDev/AccountingEntry.html), [Accounting Transaction](https://martinfowler.com/eaaDev/AccountingTransaction.html) (fetched); Square, [Books, an immutable double-entry accounting database service](https://developer.squareup.com/blog/books-an-immutable-double-entry-accounting-database-service/), 2019 (vendor engineering blog, fetched); Modern Treasury, [Ledger Transaction object](https://docs.moderntreasury.com/ledgers/reference/ledger-transaction-object) (fetched); TigerBeetle, [Data modeling](https://docs.tigerbeetle.com/coding/data-modeling/), [Account](https://docs.tigerbeetle.com/reference/account/), [Transfer](https://docs.tigerbeetle.com/reference/transfer/) (fetched).

### derived-balance

- **Situation:** Deciding whether an account balance is computed from entries or stored.
- **Structure options:** (a) derive by `SUM(amount)` over entries; (b) store a running balance on the account updated in the same transaction as each entry (Square Books updates only `books.balance`; Modern Treasury returns `resulting_ledger_account_balances` on each entry; TigerBeetle stores `debits_posted`, `credits_posted`, `debits_pending`, `credits_pending` and derives the balance from them); (c) periodic balance snapshots plus entries since the snapshot.
- **Trade-offs:** Derived is always correct but slow for long histories; stored is fast but becomes a hot row and must be updated atomically with entries; constraints like "no negative balance" need the stored form (TigerBeetle's `debits_must_not_exceed_credits` flag). Silverston shows both: Figure 8.3a "Accounting transaction details" versus 8.3b "… with account balances"; Fowler AP has Summary Account and Memo Account.
- **Sources:** as in `double-entry-ledger`; Silverston [model list](https://books.wiley.com/authors/len-silverston/models) (fetched).

### idempotency-key-table

- **Situation:** Clients retry requests (network failures, timeouts) and a retry must not charge or create twice.
- **Structure:** A table keyed by `(user_id, idempotency_key)` storing request fingerprint and the saved response; the first request inserts and locks the row, retries return the stored result or a conflict. Brandur Leach's Stripe-like design adds `locked_at`, `recovery_point` (atomic phases between foreign side effects), a staged-jobs table written in the same transaction, and a reaper for keys older than about 72 hours.
- **Trade-offs:** Stripe's documented semantics: it "saves the status code and body of the first request… including 500 errors", compares parameters and "errors if they're not the same", and keys can be pruned after 24 hours. Costs: storage and a uniqueness check per write.
- **Names in sources:** Idempotent requests (Stripe); idempotency keys (Leach).
- **Sources:** Stripe, [Idempotent requests](https://docs.stripe.com/api/idempotent_requests) (fetched); Brandur Leach, [Implementing Stripe-like Idempotency Keys in Postgres](https://brandur.org/idempotency-keys), 2017 (blog by the originator of the schema write-up, ex-Stripe; fetched).

### transactional-outbox

- **Situation:** A service must update its database and publish a message atomically, without two-phase commit.
- **Structure:** An `outbox` table written in the same transaction as the business change; a relay publishes rows by polling ("Polling publisher") or by tailing the WAL/binlog ("Transaction log tailing"). Debezium's Outbox Event Router expects columns `id` (uuid, for deduplication), `aggregatetype` (routes to topic), `aggregateid` (message key, keeps per-aggregate order), `type`, `payload`.
- **Trade-offs:** Messages are sent if and only if the transaction commits, in order; the relay may publish duplicates, so consumers must be idempotent; the table needs pruning.
- **Names in sources:** Transactional outbox, Polling publisher, Transaction log tailing (Richardson); Outbox Event Router (Debezium); Leach's `staged_jobs` is the same idea for job queues.
- **Sources:** Chris Richardson, [Transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html), [Polling publisher](https://microservices.io/patterns/data/polling-publisher.html), [Transaction log tailing](https://microservices.io/patterns/data/transaction-log-tailing.html) (fetched; originator); Debezium, [Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html) (fetched).

### processed-messages-table

- **Situation:** A consumer receives at-least-once messages and must apply each once.
- **Structure:** `processed_messages(subscriber_id, message_id)` PK, inserted in the same transaction as the business update; a duplicate-key violation means the message was already handled.
- **Names in sources:** Idempotent Consumer (Richardson; Microsoft Azure pattern of the same name); inbox table (common usage, unverified).
- **Sources:** Chris Richardson, [Idempotent Consumer](https://microservices.io/patterns/communication-style/idempotent-consumer.html) (fetched); Microsoft, [Idempotent Consumer pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/idempotent-consumer) (listed in the fetched catalog index).

### inventory-movement

- **Situation:** Stock quantities per item and location must be correct under concurrent receipts, picks, transfers and adjustments, and auditable.
- **Structure:** Treat inventory like a ledger: immutable movement rows (item, from location, to location, quantity, reason, document reference) with on-hand quantity derived or maintained as a balance per item and location; Fowler's *Analysis Patterns* ch. 6 "Inventory and Accounting" applies the same Account / Transactions / Posting Rules model to goods as to money.
- **Trade-offs:** The same derived-versus-stored balance choice as `derived-balance`; reservations (pending quantities) map to TigerBeetle-style pending transfers.
- **Names in sources:** Inventory and Accounting (Fowler AP ch. 6); Inventory item storage (Silverston Vol. 1 Fig. 3.6), Inventory assignment (Fig. 6.8), Item issuance for outgoing shipments (Fig. 5.5); Inventory (Hay ch. 4).
- **Sources:** Fowler AP [TOC](https://www.informit.com/store/analysis-patterns-reusable-object-models-9780134186054); Silverston [model list](https://books.wiley.com/authors/len-silverston/models); Hay [TOC](https://www.informit.com/store/data-model-patterns-conventions-of-thought-9780133492125) (TOCs fetched; the structure above is editorial synthesis, unverified against the book text).

## Multi-tenancy

Three vendors name the same spectrum differently. AWS's (now historical) *SaaS Storage Strategies* whitepaper: silo, bridge, pool. Microsoft's Azure SQL guidance: standalone single-tenant app, multitenant app with database-per-tenant, with a single multitenant database, with sharded multitenant databases, and a hybrid sharded model, judged on scalability, tenant isolation, per-tenant cost, development complexity, operational complexity and customizability. Citus: "single database, shared schema" (row-based sharding) versus "shared database, separate schema" (schema-based sharding, since Citus 12.0).

### shared-schema-tenancy

- **Situation:** Many small tenants, one codebase, low per-tenant cost.
- **Structure:** Every tenant-owned table has a `tenant_id`, which leads the PK and every FK in sharded setups; a catalog maps tenants to shards; enforcement by application scoping and optionally row-level security.
- **Trade-offs:** Cheapest and densest; one bad query or migration affects everyone; noisy neighbours (Microsoft antipattern "Noisy Neighbor"); AWS: "Partitioning data does not ensure that the data is isolated." Citus recommends this model: "providing a database or schema for every tenant… is often costly and impractical."
- **Names in sources:** Pool model (AWS); multitenant database (Microsoft); row-based sharding, "Partition distributed tables by a common tenant_id column" (Citus); multi-tenant data building block (DynamoDB).
- **Sources:** AWS, [SaaS Storage Strategies (PDF, 2021, historical)](https://docs.aws.amazon.com/pdfs/whitepapers/latest/multi-tenant-saas-storage-strategies/multi-tenant-saas-storage-strategies.pdf) and [SaaS Architecture Fundamentals: Data partitioning](https://docs.aws.amazon.com/whitepapers/latest/saas-architecture-fundamentals/data-partitioning.html); Microsoft, [Multitenant SaaS database tenancy patterns](https://learn.microsoft.com/en-us/azure/azure-sql/database/saas-tenancy-app-design-patterns); Citus, [Choosing Distribution Column](https://docs.citusdata.com/en/stable/sharding/data_modeling.html) (all fetched).

### schema-per-tenant

- **Situation:** Moderate tenant counts needing stronger logical separation or per-tenant schema variation, on one database server.
- **Structure:** Identical tables in one schema per tenant; the connection sets `search_path` (PostgreSQL) or equivalent.
- **Trade-offs:** AWS: lets tenants run different schema versions; migrations must run N times; catalogs bloat with many tenants. Citus schema-based sharding makes each schema a "logical shard" with only a `search_path` change, at fewer tenants per node. PostgreSQL's own "secure schema usage pattern" (user-private schemas) is the nearest official guidance; it does not discuss tenancy explicitly. Microsoft lists per-tenant *tables* in one database ("Table-based isolation") as an antipattern.
- **Names in sources:** Bridge model (AWS); schema-per-service (Richardson, the microservices analogue); schema-based sharding (Citus).
- **Sources:** AWS whitepaper (above); Citus, [Concepts](https://docs.citusdata.com/en/stable/get_started/concepts.html); PostgreSQL, [Schemas](https://www.postgresql.org/docs/current/ddl-schemas.html) §5.10.6; Microsoft, [Architectural approaches for storage and data in multitenant solutions](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/approaches/storage-data) (all fetched).

### database-per-tenant

- **Situation:** Strong isolation, per-tenant backup/restore, data residency, or large enterprise tenants.
- **Structure:** One database per tenant plus a central catalog; often combined with a shared pool for small tenants (hybrid).
- **Trade-offs:** Best isolation and per-tenant tuning; highest cost and operational overhead (fleet-wide migrations, connection counts).
- **Names in sources:** Silo model (AWS); database-per-tenant, standalone single-tenant (Microsoft); Deployment Stamps (Microsoft pattern).
- **Sources:** AWS whitepaper; Microsoft tenancy patterns and multitenant storage approaches (above).

### row-level-security

- **Situation:** Shared-schema tenancy (or per-user data) where the database itself must prevent cross-tenant reads and writes.
- **Structure:** PostgreSQL `ALTER TABLE … ENABLE ROW LEVEL SECURITY` plus `CREATE POLICY … USING (…) WITH CHECK (…)`; SQL Server security policies with predicate functions.
- **Trade-offs:** PostgreSQL: "If no policy exists for the table, a default-deny policy is used"; superusers and `BYPASSRLS` roles bypass it, table owners do unless `FORCE ROW LEVEL SECURITY`; referential integrity checks bypass policies. The official examples use `current_user`; the common tenant idiom (`current_setting('app.tenant_id')`) is not in the docs (unverified). Microsoft notes RLS is complex and "Many multitenant solutions don't use row-level security."
- **Sources:** PostgreSQL, [Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html) (fetched); Microsoft, [multitenant storage approaches](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/approaches/storage-data) (fetched).

### tenant-customization

- **Situation:** Tenants want custom fields.
- **Structure options:** JSON column for custom fields (see `json-column`), EAV, or sparse columns; Microsoft lists "Column-level tenant customization" (adding per-tenant columns) among multitenant storage antipatterns.
- **Sources:** Microsoft, [multitenant storage approaches](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/approaches/storage-data) (fetched). Weak standalone chapter; a section of `json-column` or `entity-attribute-value`.

## Scale and performance structure

Microsoft's Well-Architected [data partitioning recommendations](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/partition-data) (fetched) gives the cleanest vendor-neutral vocabulary: horizontal partitioning ("often called sharding"), vertical partitioning ("divides data by columns or fields"), and functional partitioning ("according to how each bounded context… uses the data"). It notes that its "partitioning" means separate data stores, which "differs from SQL Server table partitioning"; this inventory keeps the two apart as `horizontal-partitioning` (inside one database) and `sharding` (across databases).

### horizontal-partitioning

- **Situation:** Very large tables where most queries hit a predictable slice (by time, region, tenant), and old data must be archived or dropped cheaply.
- **Structure:** One logical table split by a partition key into range, list or hash partitions, with partition pruning at plan or execution time.
  - PostgreSQL declarative partitioning: range ("inclusive at the lower end and exclusive at the upper end"), list, hash ("modulus and a remainder"); legacy "partitioning using inheritance" allows arbitrary rules but nothing verifies that the CHECK constraints are mutually exclusive.
  - MySQL: RANGE, LIST, RANGE/LIST COLUMNS, HASH, KEY.
  - SQL Server: partition function + partition scheme, aligned indexes, partition switching; also local partitioned views (`UNION ALL` over tables with disjoint trusted CHECK constraints), which Microsoft now ranks below partitioned tables.
  - Oracle: range, list, hash, interval (partitions created automatically), reference (children "equipartitioned by inheriting the partitioning key from the parent table without duplicating the key columns"), composite.
- **Trade-offs:** Big wins for retention (detach/drop/switch a partition) and maintenance; Microsoft: "partitioning rarely improves performance in OLTP systems". Unique keys must include the partition key on PostgreSQL ("the constraint's columns must include all of the partition key columns"), MySQL ("every unique key on the table must use every column in the table's partitioning expression") and SQL Server; partitioned InnoDB tables cannot have FKs at all. PostgreSQL: "Never just assume that more partitions are better than fewer partitions, nor vice-versa."
- **Names in sources:** table partitioning; partitioned table; partitioned view (SQL Server); time partitioning; the hand-rolled version is Karwin's "Metadata Tribbles".
- **Sources:** PostgreSQL, [Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html); MySQL 8.4, [Partitioning Types](https://dev.mysql.com/doc/refman/8.4/en/partitioning-types.html), [Partitioning Keys, Primary Keys, and Unique Keys](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-partitioning-keys-unique-keys.html), [Partitioning Limitations Relating to Storage Engines](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-storage-engines.html); Microsoft, [Partitioned tables and indexes](https://learn.microsoft.com/en-us/sql/relational-databases/partitions/partitioned-tables-and-indexes), [CREATE VIEW: partitioned views](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-view-transact-sql); Oracle, [Partitioning Concepts](https://docs.oracle.com/en/database/oracle/oracle-database/19/vldbg/partition-concepts.html) (all fetched).

### sharding

- **Situation:** Data or write volume beyond one server; tenants or customers that are mostly independent.
- **Structure:** Same schema on many databases; a shard key routes each row; related tables are co-located on the same key so joins and transactions stay local; small reference tables are replicated to every shard. Citus: "distribution column", "co-location", "reference table", and the rule that "primary and foreign key constraints include the distribution column" (keys become composite with `tenant_id`). Azure SQL elastic database tools: shardlets, a shard map manager, list and range shard maps.
- **Trade-offs:** Microsoft: the shard key "can be difficult to change after the system is in operation"; avoid hot partitions (hash the key rather than, say, the first letter of a name); cross-shard joins, transactions and referential integrity move into the application.
- **Names in sources:** Sharding pattern, shard key, shardlet (Microsoft); distributed table, distribution column (Citus); partition key (DynamoDB, Cosmos DB, Cassandra).
- **Sources:** Microsoft, [Sharding pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/sharding) (listed in the fetched catalog index) and [data partitioning recommendations](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/partition-data) (fetched); Citus, [Concepts](https://docs.citusdata.com/en/stable/get_started/concepts.html), [Choosing Distribution Column](https://docs.citusdata.com/en/stable/sharding/data_modeling.html), [Multi-tenant Applications](https://docs.citusdata.com/en/stable/use_cases/multi_tenant.html) (fetched).

### vertical-partitioning

- **Situation:** Wide rows where a few columns are hot and others are large, rarely read, volatile or sensitive.
- **Structure:** Split one entity into a 1:1 pair of tables sharing the PK (core and details, product and inventory counters, user and credentials).
- **Trade-offs:** Microsoft: separate "slow-moving data… from more dynamic data", isolate sensitive fields, reduce concurrent access; the cost is a join and the need to keep the 1:1 consistent. PostgreSQL's TOAST already moves values larger than about 2 kB out of line, so the gain for large text is smaller there than on engines without it. DynamoDB lists vertical partitioning as a building block for large items.
- **Names in sources:** Vertical partitioning (Microsoft, DynamoDB); one-to-one split; Split Table (Ambler/Sadalage).
- **Sources:** Microsoft (above); PostgreSQL, [TOAST](https://www.postgresql.org/docs/current/storage-toast.html) (fetched); AWS, [Data modeling building blocks](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/data-modeling-blocks.html) (fetched).

### summary-table

- **Situation:** Dashboards and lists repeatedly aggregate large tables (daily totals, per-customer counts).
- **Structure:** A table of pre-aggregated rows keyed by the grouping columns and refreshed incrementally (on write, by triggers, by a job) or wholesale; in PostgreSQL a materialized view, refreshed with `REFRESH MATERIALIZED VIEW [CONCURRENTLY]`.
- **Trade-offs:** PostgreSQL: "often much faster… the data is not always current; yet sometimes current data is not needed"; `CONCURRENTLY` needs a unique index on plain columns and the view populated, and is costlier when many rows change; materialized views cannot be updated directly. Microsoft's Materialized View pattern: "Generate prepopulated views over the data in one or more data stores when the data is poorly formatted for required query operations."
- **Names in sources:** materialized view (PostgreSQL, Oracle, Microsoft pattern); aggregated fact tables (Kimball); rollup/summary table (common usage); Computed Pattern and Bucket Pattern (MongoDB); Summary Account (Fowler AP 6.3).
- **Sources:** PostgreSQL, [Materialized Views](https://www.postgresql.org/docs/current/rules-materializedviews.html), [REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/current/sql-refreshmaterializedview.html) (fetched); Microsoft, [Materialized View pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/materialized-view) (listed in the fetched index).

### counter-cache

- **Situation:** Lists show child counts (comments per post) and `COUNT(*)` per row is too slow.
- **Structure:** An integer column on the parent (`comments_count DEFAULT 0`) incremented and decremented with child inserts and deletes, by the ORM or by triggers.
- **Trade-offs:** O(1) reads; hot-row contention on popular parents and drift if any write path bypasses the maintenance code (periodic reconciliation needed). For approximate counts, MongoDB's Approximation Pattern updates only occasionally.
- **Names in sources:** `counter_cache` (Rails); Computed Pattern (MongoDB); Introduce Calculated Column, Add Trigger for Calculated Column (Ambler/Sadalage).
- **Sources:** Rails, [Active Record Associations](https://guides.rubyonrails.org/association_basics.html) (counter_cache, fetched); [databaserefactoring.com](https://databaserefactoring.com/) (fetched).

### cqrs-read-model

- **Situation:** Read and write workloads want different shapes, scale or consistency.
- **Structure:** Writes go to a normalized (or event-sourced) model; one or more denormalized read tables or stores are updated from it, synchronously or via events.
- **Trade-offs:** Fowler: with separate databases the query side becomes "a real-time ReportingDatabase", and for most systems CQRS adds "risky complexity". Read models are eventually consistent.
- **Sources:** Fowler, [CQRS](https://martinfowler.com/bliki/CQRS.html) (fetched); Microsoft, [CQRS pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/cqrs) (listed in fetched index); Chris Richardson, [CQRS](https://microservices.io/patterns/data/cqrs.html) (fetched; read-only view database updated by subscribing to domain events; drawbacks: complexity, duplication, replication lag).

### index-table

- **Situation:** A store that can only be queried efficiently by its primary or partition key needs lookups by other attributes.
- **Structure:** A secondary table keyed by the alternate attribute pointing at the primary key (or duplicating needed columns); in DynamoDB, GSIs play this role.
- **Sources:** Microsoft, [Index Table pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/index-table) (listed in the fetched index; data partitioning page describes it as letting applications "locate data by alternate keys without scanning every partition").

### partial-index

- **Situation:** Queries target a small, predicate-defined subset (open orders, non-deleted rows, unprocessed jobs).
- **Structure:** An index with a `WHERE` predicate (PostgreSQL, SQLite; filtered index in SQL Server); also used for conditional uniqueness (unique email among non-deleted users).
- **Names in sources:** sparse index (DynamoDB), filtered index (SQL Server sparse-columns docs).
- **Sources:** AWS, [sparse indexes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes-general-sparse-indexes.html) (fetched); Microsoft, [Use sparse columns](https://learn.microsoft.com/en-us/sql/relational-databases/tables/use-sparse-columns) (fetched; recommends filtered indexes alongside). PostgreSQL's partial-index page was not fetched in this pass (unverified citation).

### unlogged-staging-table

- **Situation:** Bulk loads, scratch data and caches that can be rebuilt after a crash.
- **Structure:** PostgreSQL `UNLOGGED` tables: "considerably faster… not crash-safe: an unlogged table is automatically truncated after a crash… not replicated to standby servers"; not allowed for partitioned tables in 18.
- **Sources:** PostgreSQL, [CREATE TABLE](https://www.postgresql.org/docs/current/sql-createtable.html) (fetched). Celko distinguishes staging tables from base and auxiliary tables (see `celko-auxiliary-tables`). Weak standalone chapter; fits as a variant.

## Analytics and warehouse modeling

Kimball Group's own [Dimensional Modeling Techniques](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/) index (fetched) lists 81 named techniques in nine groups: Fundamental Concepts, Basic Fact Table Techniques, Basic Dimension Table Techniques, Integration via Conformed Dimensions, Slowly Changing Dimension Techniques, Dimension Hierarchy Techniques, Advanced Fact Table Techniques, Advanced Dimension Table Techniques, Special Purpose Schemas. It is itself a pattern catalog; the entries below cover the techniques that change table structure. Individual technique pages live under the index URL plus a slug (e.g. `junk-dimension/`); all quoted ones were fetched. Below, "Kimball index" means that page.

### star-schema

- **Situation:** Analytical queries over business process measurements, sliced by descriptive context, by users who write their own queries.
- **Structure:** A central fact table at a declared grain (one row per measurement event) with surrogate FKs to denormalized dimension tables; implemented relationally as a star or as an OLAP cube derived from it. Kimball's "four step dimensional design process": choose the business process, declare the grain, identify dimensions, identify facts.
- **Trade-offs:** Simple, fast joins and understandable for users; redundancy in dimensions; updates are ETL's job, not the application's.
- **Names in sources:** "Star Schemas and OLAP Cubes", "Grain", "Four step dimensional design process" (Kimball index); star schema (Silverston Vol. 1 ch. 12–14 show sales, HR, inventory star schemas).
- **Sources:** Kimball index and [Star Schemas and OLAP Cubes](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/star-schema-olap-cube/) (fetched); Silverston model list (fetched).

### snowflake-schema

- **Situation:** Dimension hierarchies normalized into separate tables (product → brand → category).
- **Trade-offs:** Kimball advises against it: harder to navigate, slower, and a flattened dimension holds the same information. Outrigger dimensions (a dimension referencing another) are a limited, sanctioned form, "used sparingly".
- **Names in sources:** "Snowflaked Dimensions", "Outrigger Dimensions" (Kimball index).
- **Sources:** Kimball, [Snowflaked Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/snowflake-dimension/), [Outrigger Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/outrigger-dimension/) (fetched).

### fact-table-types

- **Situation:** Different measurement rhythms need different fact table shapes.
- **Structure:** Transaction fact (one row per event, exists only when something happens); Periodic snapshot (one row per entity per period, even if nothing happened); Accumulating snapshot (one row per process instance with one date FK per milestone, updated as milestones occur); Factless fact (dimension intersections with no measure, e.g. attendance or coverage, used to find what did not happen). Advanced variants in the index: Aggregated fact tables, Consolidated fact tables, Header/line fact tables, Centipede fact table (an anti-pattern there), Timespan tracking in fact tables.
- **Trade-offs:** Accumulating snapshots are the only Kimball facts that are updated in place; periodic snapshots carry semi-additive measures (balances) that cannot be summed across time.
- **Sources:** Kimball, [Transaction Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/transaction-fact-table/), [Periodic Snapshot Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/periodic-snapshot-fact-table/), [Accumulating Snapshot Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/accumulating-snapshot-fact-table/), [Factless Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/factless-fact-table/) (fetched).

### special-dimensions

- **Degenerate dimension:** a dimension key with no table (invoice number on the line fact).
- **Junk dimension:** miscellaneous low-cardinality flags combined into one dimension holding only occurring combinations; also "transaction profile dimension".
- **Role-playing dimension:** one physical dimension referenced several times (order date, ship date), each role exposed as a view with distinct column names.
- **Conformed dimension:** shared column names and domain values across fact tables to allow drilling across; the basis of the "Enterprise data warehouse bus matrix".
- **Audit dimension:** ETL metadata (quality flags, code version, load time) attached to facts.
- **Calendar date dimension:** one row per day with fiscal and holiday attributes (the warehouse form of Celko's auxiliary calendar table).
- **Sources:** Kimball, [Degenerate Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/degenerate-dimension/), [Junk Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/junk-dimension/), [Role-Playing Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/role-playing-dimension/), [Conformed Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/conformed-dimension/), [Audit Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/audit-dimension/) (fetched); "Calendar date dimension" is listed on the Kimball index (page not fetched).

### bridge-table

- **Situation:** A fact relates to several values of a dimension (a claim with several diagnoses, an account with several owners), or a hierarchy is ragged/variable depth.
- **Structure:** Multivalued: a group key on the fact and a bridge `(group_key, dimension_key[, weight])`; with Type 2 dimensions the bridge needs effective and expiration timestamps. Ragged hierarchies: a bridge holding every ancestor/descendant path (structurally a closure table), or a simpler "pathstring" attribute (structurally path enumeration) that handles shared ownership and restructuring poorly.
- **Sources:** Kimball, [Multivalued Dimensions and Bridge Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/multivalued-dimension-bridge-table/), [Ragged/Variable Depth Hierarchies](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/ragged-variable-depth-hierarchy/) (fetched).

### slowly-changing-dimension

- **Situation:** Dimension attributes change (customer moves) and reports must show either current or as-was values.
- **Structure (Kimball's numbered types):** Type 0 retain original; Type 1 overwrite (history lost, aggregates recomputed); Type 2 add new row with a new surrogate key plus at least effective date, expiration date and current-row indicator; Type 3 add a "prior value" column ("alternate reality", used infrequently); Type 4 add mini-dimension for rapidly changing attributes, fact carries both keys; Type 5 mini-dimension plus Type 1 outrigger pointer to the current mini-dimension row; Type 6 Type 2 row that also carries current-value columns overwritten across all rows of the durable key; Type 7 fact carries both surrogate and durable key, with current and historical views. There is no separate "hybrid" page; 5–7 are the hybrids.
- **Trade-offs:** Type 2 is the default for history but multiplies rows and needs durable keys to group versions; Types 6/7 trade ETL complexity for easy current-value reporting.
- **Names in sources:** Slowly Changing Dimension Techniques (Kimball index); MongoDB's manual also has a "Slowly Changing Dimensions" versioning page.
- **Sources:** Kimball [Type 0](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-0/), [Type 1](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-1/), [Type 2](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-2/), [Type 3](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-3/), [Type 4](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-4-mini-dimension/), [Type 5](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-5/), [Type 6](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-6/), [Type 7](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-7/) (all fetched).

### supertype-subtype-fact-schema

- **Situation:** Heterogeneous products (checking vs mortgage accounts) share core facts but have type-specific attributes.
- **Structure:** A core fact and dimension for shared attributes, plus custom fact/dimension tables per subtype.
- **Sources:** Kimball index, "Supertype and subtype schemas for heterogeneous products" (listed; page not fetched). Warehouse counterpart of class-table inheritance.

### data-vault

- **Situation:** An enterprise integration layer over many changing sources that must keep full history, load in parallel and absorb new sources by extension.
- **Structure:** Hubs ("a single table carrying at a minimum a unique list of business keys"); Links ("a physical representation of a many-to-many 3NF relationship" between hubs); Satellites ("Hub key context (descriptive) information", historized by load date). Linstedt's 2002 overview also mentions a point-in-time table "constructed for ease of joins". Data Vault 2.0 adds hash keys, bridge tables, same-as and hierarchical links, effectivity and multi-active satellites.
- **Trade-offs:** Insert-only, auditable and extensible; many joins, so it is not queried directly but feeds marts (often star schemas).
- **Names in sources:** Data Vault, Hubs, Links, Satellites (Linstedt).
- **Sources:** Dan Linstedt, [Data Vault Series 1 – Data Vault Overview](https://www.dataversity.net/articles/data-vault-series-1-data-vault-overview/), TDAN.com, 2002 (fetched; originator). **Unverified:** the Data Vault Alliance site ([datavaultalliance.com](https://datavaultalliance.com/), fetched) publishes no definitions; Data Vault 2.0 entity types (PIT, bridge, same-as link, hierarchical link, effectivity and multi-active satellites, hash-key rules) are documented only in Linstedt and Olschimke, *Building a Scalable Data Warehouse with Data Vault 2.0* (2015, not read) and in vendor tooling docs.

### anchor-modeling

- **Situation:** Data environments where requirements keep changing and every past schema version must remain usable.
- **Structure:** 6NF: anchors (sets of entities), attributes (static, historized, knotted static, knotted historized), ties (associations between anchors, same four variants), knots (small fixed value sets such as gender). Views and functions (latest, point-in-time, interval) reassemble wide rows; performance depends on the optimizer's table elimination.
- **Trade-offs:** Changes "only require extensions, not modifications", and "all previous versions of the database schema are available as subsets of the current schema"; very many tables and reliance on table elimination.
- **Sources:** [anchormodeling.com/about](https://www.anchormodeling.com/about/) (fetched); Rönnbäck, Regardt, Bergholtz, Johannesson, Wohed, "Anchor modeling — Agile information modeling in evolving data environments", *Data & Knowledge Engineering* 69(12), 2010, [DOI 10.1016/j.datak.2010.10.002](https://doi.org/10.1016/j.datak.2010.10.002) and [author preprint](https://www.anchormodeling.com/wp-content/uploads/2011/05/Anchor-Modeling.pdf) (preprint fetched).

### one-big-table

- **Situation:** Columnar cloud warehouses where storage is cheap and joins are expensive; consumers are BI tools.
- **Structure:** A wide denormalized table per business entity or event; in BigQuery, nested `STRUCT` and repeated `ARRAY` fields keep one-to-many children inside the parent row.
- **Trade-offs:** BigQuery: "It's best to use this strategy when the relationships are hierarchical and frequently queried together"; fully flattening causes shuffling, and star schemas are already optimized. A Fivetran benchmark found 25–50% faster queries at roughly three times the storage. dbt's guide recommends marts "wide and denormalized" but staying normalized when using its Semantic Layer.
- **Names in sources:** OBT, one big table (Fivetran); wide tables (dbt); nested and repeated fields (BigQuery). **Unverified:** no originator of the term "OBT" was found.
- **Sources:** Google, [Use nested and repeated fields](https://docs.cloud.google.com/bigquery/docs/best-practices-performance-nested) (fetched); Kaminsky, [Data warehouse modeling: Star schema vs. OBT](https://www.fivetran.com/blog/star-schema-vs-obt), Fivetran, 2022 (fetched; vendor benchmark); dbt Labs, [Marts](https://docs.getdbt.com/best-practices/how-we-structure/4-marts) (fetched).

### reporting-database

- **Situation:** Reports and analytics put load on, or need a different shape than, the operational schema.
- **Structure:** A separate database with a schema designed for reporting, fed from the operational one; with CQRS the query side can become "a real-time ReportingDatabase".
- **Sources:** Fowler, [ReportingDatabase](https://martinfowler.com/bliki/ReportingDatabase.html) and [CQRS](https://martinfowler.com/bliki/CQRS.html) (fetched).

## Concurrency and workflow structures

### queue-table

- **Situation:** Background jobs or tasks that must be enqueued transactionally with business data and consumed by several workers without double processing.
- **Structure:** A jobs table with `run_at`, `priority`, `queue`, `attempts`, `locked_by/locked_at`, `finished_at`; workers claim rows with `SELECT … FOR UPDATE SKIP LOCKED LIMIT n`. Solid Queue splits job state into separate tables (`ready_executions`, `scheduled_executions`, `claimed_executions`, `blocked_executions`, `failed_executions`) each with a unique `job_id`, and restricts polling to two query shapes "to ensure a covering index is always used". River: "A job inserted in a transaction becomes visible to workers only after the transaction commits." GoodJob instead uses session-level advisory locks plus `LISTEN/NOTIFY`.
- **Trade-offs:** PostgreSQL: "Skipping locked rows provides an inconsistent view of the data, so this is not suitable for general purpose work, but can be used to avoid lock contention with multiple consumers accessing a queue-like table." Costs: table bloat from churn, vacuum pressure, polling load; Cassandra explicitly warns against queue designs because deletes create tombstones.
- **Names in sources:** queue-like table (PostgreSQL); Solid Queue, River, GoodJob (job libraries); Competing Consumers, Queue-Based Load Leveling (Microsoft patterns, broker-level).
- **Sources:** PostgreSQL, [SELECT: The Locking Clause](https://www.postgresql.org/docs/current/sql-select.html) (fetched); Rails, [Solid Queue README](https://github.com/rails/solid_queue) and [queue schema](https://raw.githubusercontent.com/rails/solid_queue/main/lib/generators/solid_queue/install/templates/db/queue_schema.rb); [River docs](https://riverqueue.com/docs); [GoodJob README](https://github.com/bensheldon/good_job) (all fetched); Cassandra [logical data modeling](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/data-modeling_logical.html) (fetched). **Unverified:** Craig Ringer's original post on SKIP LOCKED for queues (its company-blog URL now redirects to the EDB home page).

### version-column

- **Situation:** Concurrent edits, often across a user's think time, must not silently overwrite each other, and holding locks is unacceptable.
- **Structure:** An integer `version` (or `lock_version`) column; `UPDATE … SET …, version = version + 1 WHERE id = ? AND version = ?`; zero rows affected means a conflict. SQL Server `rowversion` is an 8-byte database-wide counter incremented on every update (even no-op), "a poor candidate for keys".
- **Trade-offs:** No locks held, conflicts detected late; the version must travel with the client (Rails advises a hidden form field). Hibernate also offers timestamp versions and "versionless" optimistic locking that compares all columns.
- **Names in sources:** Optimistic Offline Lock (Fowler PoEAA); `lock_version` (Rails); `@Version` (JPA/Hibernate); `rowversion` (SQL Server); `UNIQUE(stream_id, version)` in event stores (see `event-sourcing`).
- **Sources:** Fowler, [Optimistic Offline Lock](https://martinfowler.com/eaaCatalog/optimisticOfflineLock.html) (catalog fetched); Rails, [Locking::Optimistic](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Optimistic.html); Hibernate [User Guide 6.6](https://docs.hibernate.org/orm/6.6/userguide/html_single/Hibernate_User_Guide.html) §11.1; Microsoft, [rowversion](https://learn.microsoft.com/en-us/sql/t-sql/data-types/rowversion-transact-sql) (all fetched).

### lock-table

- **Situation:** A business transaction spanning several requests needs exclusive ownership of a record (editing a document, processing a claim).
- **Structure:** A table of `(lockable_type, lockable_id, owner, acquired_at, expires_at)` with a unique constraint on the locked item; acquisition is an insert, release a delete, with expiry for abandoned locks.
- **Names in sources:** Pessimistic Offline Lock, Coarse-Grained Lock, Implicit Lock (Fowler PoEAA); Solid Queue's `semaphores (key UNIQUE, value, expires_at)` is a live example.
- **Sources:** Fowler, [Pessimistic Offline Lock](https://martinfowler.com/eaaCatalog/pessimisticOfflineLock.html) (catalog fetched; table form from the book, unverified online); Solid Queue schema (above).

### saga-state-table

- **Situation:** A business process spans several services or long-running steps and must be resumable and compensatable.
- **Structure:** A table per process instance holding current step, status and correlation ids, advanced by local transactions; failed steps trigger compensating transactions.
- **Trade-offs:** Richardson: sagas suffer "lack of isolation", which requires countermeasures. The state table itself is not specified by the source (structure unverified as a named pattern); Leach's `recovery_point` column is a single-service version.
- **Sources:** Chris Richardson, [Saga](https://microservices.io/patterns/data/saga.html) (fetched); Brandur Leach, [idempotency keys](https://brandur.org/idempotency-keys) (fetched).

## Document, key-value and wide-column modeling

The vendors converge on one principle stated three ways: model for the access patterns, keep together what is read together, and accept duplication. MongoDB: embed "when data is queried together, updated together, archived together" ([Best Practices for Data Modeling](https://www.mongodb.com/docs/manual/data-modeling/best-practices/)); DynamoDB: "you shouldn't start designing your schema for DynamoDB until you know the questions it will need to answer" ([NoSQL design](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html)); Cassandra: "In Cassandra, data modeling is query-driven" ([intro](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/intro.html)). All fetched.

MongoDB has two overlapping pattern lists. The blog series "Building with Patterns" (Ken W. Alger and Daniel Coupal, 2019; [summary](https://www.mongodb.com/company/blog/building-with-patterns-a-summary), fetched) names 12 patterns with a use-case matrix over Catalog, Content Management, IoT, Mobile, Personalization, Real-Time Analytics and Single View. The current manual ([Schema Design Patterns](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/), fetched) regroups them into Handle Computed Values (Computed, Approximation), Group Data (Bucket, Outlier, Attribute, Subset), Polymorphic Data (Polymorphic, Inheritance), Document and Schema Versioning (Keep Document History, Maintain Versions, Slowly Changing Dimensions), Archive and Single Collection. Extended Reference, Tree and Preallocated survive only in the blog.

### embed-or-reference

- **Situation:** In a document store, deciding whether related data lives inside the parent document or in its own collection.
- **Structure:** Embed for contained, one-to-few, co-read, co-updated data; reference (store IDs) for high-cardinality or unbounded children, data written at different times, or children that exist without a parent. Cosmos DB adds: put the reference on the side that grows, use ID arrays on both sides for many-to-many, and "hybrid data models" that denormalize a subset.
- **Trade-offs:** MongoDB: "distributed transaction… should not be a replacement for effective schema design." Embedding favours reads, referencing favours writes (Cosmos DB).
- **Sources:** MongoDB, [Best Practices for Data Modeling](https://www.mongodb.com/docs/manual/data-modeling/best-practices/) ("Link Related Data" table); Microsoft, [Azure Cosmos DB data modeling](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/modeling-data) (both fetched).

### attribute-pattern

- **Situation:** Many similar fields (release dates per country, sizes per unit) each needing an index, or sparse fields varying per document.
- **Structure:** Move the fields into an array of `{k, v}` sub-documents and index the array once (compound index on `k`, `v`).
- **Trade-offs:** Fewer indexes and simpler queries; the post states no downsides; typing per key is lost, the document-store form of EAV.
- **Sources:** MongoDB blog, [The Attribute Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-attribute-pattern); manual, [Attribute Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/attribute-pattern/) (fetched).

### bucket-pattern

- **Situation:** High-volume time series (IoT readings) where one document per measurement bloats indexes.
- **Structure:** One document per entity per time span holding an array of measurements plus pre-aggregates (count, sum).
- **Trade-offs:** Far fewer documents and index entries, cheap range summaries; bucket boundaries must be chosen up front. MongoDB 5.0+ time series collections implement it natively.
- **Sources:** MongoDB blog, [The Bucket Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-bucket-pattern); manual, [Bucket Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/bucket-pattern/) (fetched). Relational analogue: summary/rollup tables; Cassandra's partition "bucketing".

### computed-pattern

- **Situation:** The same expensive calculation repeated on every read with a high read/write ratio.
- **Structure:** Store the result in the document, updated on write or on a schedule.
- **Trade-offs:** Fast reads; staleness or write amplification. Relational analogues: counter cache, summary table, generated column, materialized view.
- **Sources:** MongoDB blog, [The Computed Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-computed-pattern); manual, [Computed Data](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/computed-values/computed-schema-pattern/) (fetched).

### approximation-pattern

- **Situation:** Expensive counters (page views, population) where precision does not matter.
- **Structure:** Update the stored value only occasionally, e.g. "update by 100, 1% of the time".
- **Trade-offs:** Far fewer writes; "exact numbers aren't being represented and… the implementation must be done in the application itself."
- **Sources:** MongoDB blog, [The Approximation Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-approximation-pattern) (fetched).

### outlier-pattern

- **Situation:** A few extreme documents (a bestseller's buyer list) would dictate the design for everyone or hit the 16 MB document limit.
- **Structure:** Flag outliers (`has_extras: true`) and move overflow into linked documents; normal documents stay simple.
- **Trade-offs:** Design is optimized for the common case; ad hoc queries on outliers perform worse and the application must handle the flag.
- **Sources:** MongoDB blog, [The Outlier Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-outlier-pattern); manual, [Outlier Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/outlier-pattern/) (fetched).

### subset-pattern

- **Situation:** Documents with large arrays (all reviews) push the working set beyond RAM though only a few items are usually shown.
- **Structure:** Keep a hot subset (10 most recent reviews) embedded and the rest in another collection.
- **Trade-offs:** Smaller hot documents; duplication and extra round trips for the full set. The manual also prescribes it as the fix for the "Reduce $lookup Operations" anti-pattern.
- **Sources:** MongoDB blog, [The Subset Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-subset-pattern); manual, [Subset Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/subset-pattern/) (fetched).

### extended-reference-pattern

- **Situation:** Frequent joins only to fetch a few fields of the referenced entity (customer name on an order).
- **Structure:** Keep the reference and copy the frequently read, rarely changing fields into the referencing document.
- **Trade-offs:** "data duplication is a side effect", so updates of the copied fields must be planned; best for fields that rarely change. Relational analogue: selective denormalization; Fowler-style snapshotting of address at order time is a legitimate reason for the copy.
- **Sources:** MongoDB blog, [The Extended Reference Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-extended-reference-pattern) (fetched).

### polymorphic-collection

- **Situation:** Documents of several types "with more similarities than differences" that need to be queried together.
- **Structure:** One collection with a type discriminator; the manual adds an Inheritance Pattern (parent fields shared, child types add fields) and "Specify Validation for Polymorphic Collections".
- **Trade-offs:** Summary: "Easy to implement. Queries can run across a single collection." The document-store counterpart of Single Table Inheritance.
- **Sources:** MongoDB blog summary (fetched; the standalone Polymorphic post returned 404); manual, [Polymorphic Data](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/polymorphic-data/) (fetched).

### schema-versioning-pattern

- **Situation:** Changing document shape without downtime or a big-bang migration.
- **Structure:** A `schema_version` field (missing = v1); the application handles each version; migration eager, on access, or never.
- **Trade-offs:** No downtime; the application must read several versions and may need two indexes during migration. Relational analogue: expand/contract.
- **Sources:** MongoDB blog, [The Schema Versioning Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-schema-versioning-pattern) (fetched); manual "Maintain Versions" under [design patterns](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/).

### document-versioning-pattern

- **Situation:** Keeping prior revisions of documents (legal, insurance) without a separate system, when revisions per document are few.
- **Structure:** A `version` field on the current document plus a separate revisions collection.
- **Trade-offs:** Simple current-state queries; more writes; "does not… replace a dedicated version control system." Relational analogue: history table / system-versioned table.
- **Sources:** MongoDB blog, [The Document Versioning Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-document-versioning-pattern) (fetched).

### preallocation-pattern

- **Situation:** A known structure to be filled later (seat map, calendar grid).
- **Structure:** Create the empty structure up front.
- **Trade-offs:** The post says it "has lost its generic use case" since WiredTiger removed in-place growth concerns; trade-off "simplicity versus performance". Weak chapter candidate.
- **Sources:** MongoDB blog, [The Preallocation Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-preallocation-pattern) (fetched).

### document-tree-models

- **Situation:** Hierarchies in a document store.
- **Structure:** Five manual tutorials: Parent References, Child References, Array of Ancestors, Materialized Paths, Nested Sets; the blog Tree pattern recommends an ancestors array plus parent with a multikey index.
- **Trade-offs:** Array of Ancestors is "slightly slower than the Materialized Paths pattern but is more straightforward to use"; Nested Sets are "best for static trees"; subtree traversal on parent references needs `$graphLookup`.
- **Sources:** MongoDB, [Model Tree Structures](https://www.mongodb.com/docs/manual/applications/data-models-tree-structures/); blog, [The Tree Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-tree-pattern) (fetched).

### archive-pattern

- **Situation:** Old data in the hot store degrades performance and costs money.
- **Structure:** Move it to object storage, a separate cluster or a separate collection, archiving embedded snapshots because "all relevant components of the data must be from the same time."
- **Sources:** MongoDB manual, [Archive Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/archive/) (fetched). Relational analogues: partition detach/drop, cold-table split.

### single-collection-pattern

- **Situation:** Several related document types read together with low latency and no joins.
- **Structure:** All types in one collection with a `doc_type` and a `links: [{target, doc_type}]` array indexed so one query returns a document and its relatives.
- **Sources:** MongoDB manual, [Single Collection Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/single-collection/) (fetched). The MongoDB counterpart of DynamoDB single-table design.

### schema-validation

- **Situation:** A schemaless store where an established application needs guarantees about field types and ranges.
- **Structure:** `$jsonSchema` validators per collection, with configurable level and warn-or-reject behaviour.
- **Sources:** MongoDB, [Schema Validation](https://www.mongodb.com/docs/manual/core/schema-validation/) (fetched): "most useful for an established application with a defined data structure."

### single-table-design

- **Situation:** DynamoDB applications whose access patterns read several entity types together and want one request per page.
- **Structure:** One table, generic key attributes (`PK`, `SK`), entity-prefixed key values (`CUSTOMER#123`, `ORDER#2026-11-10#9`), item collections that pre-join related items under one partition key, and overloaded GSIs.
- **Trade-offs:** AWS's official comparison lists single-table disadvantages: steep learning curve, all-or-nothing backups and encryption, Standard-IA less useful, one stream for all changes, harder with GraphQL and mappers; and: "If your application's access patterns do not have the need to query multiple entities or tables together, then multiple table design is a good and sufficient approach." Alex DeBrie (AWS Hero, guest post on the AWS Database Blog) gives the materialized-join argument and when to prefer multiple tables.
- **Sources:** AWS, [NoSQL design for DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html) ("maintain as few tables as possible"); [Data modeling foundations in DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/data-modeling-foundations.html) (all fetched); DeBrie, [Single-table vs. multi-table design in Amazon DynamoDB](https://aws.amazon.com/blogs/database/single-table-vs-multi-table-design-in-amazon-dynamodb/), 2022 (fetched; guest post, not AWS staff).

### adjacency-list-dynamodb

- **Situation:** Many-to-many relationships and graphs in a key-value store.
- **Structure:** "Adjacency list design pattern": the entity is the partition key, each edge is an item whose sort key is the target ID, and a GSI on the sort key gives the inverse direction. AWS also describes a "Materialized graph pattern" with node and edge items and overloaded GSIs, and recommends Neptune for multi-hop traversal.
- **Trade-offs:** "minimal data duplication"; one-hop queries only.
- **Sources:** AWS, [Best practices for managing many-to-many relationships](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-adjacency-graphs.html) (fetched). Not the same as the relational adjacency list for trees, despite the name.

### gsi-overloading

- **Situation:** More query patterns than the GSI limit, over items of different types.
- **Structure:** A shared attribute (`Data`) holding different content per item type, indexed by one GSI with `SK` as its partition key.
- **Sources:** AWS, [Overloading Global Secondary Indexes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-gsi-overloading.html) (fetched).

### sparse-index

- **Situation:** Querying a small subset of items (open orders, award winners) without scanning.
- **Structure:** Write the index key attribute only on items that qualify; the index contains only those. Relational analogue: partial index (`CREATE INDEX ... WHERE`).
- **Sources:** AWS, [Take advantage of sparse indexes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes-general-sparse-indexes.html) (fetched).

### composite-sort-key

- **Situation:** Hierarchical or multi-criteria lookups within a partition.
- **Structure:** Concatenated sort key `[country]#[region]#[state]#[county]#[city]` queried with `begins_with`; AWS also documents "Using sort keys for version control": a `v0_` item always holds the latest copy and `v1_…vN_` items hold history.
- **Sources:** AWS, [Best practices for using sort keys](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-sort-keys.html); [Data modeling building blocks](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/data-modeling-blocks.html) (fetched). Key-value form of path enumeration and of a history table.

### write-sharding

- **Situation:** A hot partition key (today's date, a popular item) exceeds per-partition throughput.
- **Structure:** Append a random suffix (reads scatter-gather) or a calculated suffix (point reads still possible) to spread writes.
- **Sources:** AWS, [Using write sharding](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-sharding.html) (fetched). Related: Cosmos DB synthetic partition keys.

### table-per-period

- **Situation:** High-volume time series where recent data is hot and old data is cold.
- **Structure:** "one table per application per period"; pre-create the next table, scale down or move old ones to a cheaper class.
- **Sources:** AWS, [Best practices for handling time series data](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-time-series.html) (fetched). Note the tension with Karwin's "Metadata Tribbles"; relational engines solve it with native partitioning instead.

### large-item-offload

- **Situation:** Items larger than the store's limit (DynamoDB 400 KB).
- **Structure:** Compress, split vertically into an item collection, or store a pointer to object storage.
- **Trade-offs:** Compressed values are "not useful for filtering"; S3 pointers mean no cross-service transactions and possible orphans.
- **Sources:** AWS, [Best practices for storing large items and attributes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-use-s3-too.html) (fetched). Relational analogue: TOAST, vertical split, Karwin's "Phantom Files".

### query-first-table-design

- **Situation:** Wide-column stores without joins (Cassandra, ScyllaDB, Bigtable-style).
- **Structure:** One table per query, named `x_by_y` (`hotels_by_poi`); partition key from the equality predicates, clustering columns from range and ordering needs; data duplicated across tables. Chebotko's methodology formalizes it: principles Know Your Data, Know Your Queries, Data Nesting, Data Duplication, and mapping rules MR1–MR5, drawn as Chebotko diagrams (K, C↑/C↓, S).
- **Trade-offs:** "denormalization is, well, perfectly normal"; partition size must be bounded (docs: hard limit 2 billion cells per partition; bucket by adding a column such as month to the partition key); deletion-heavy designs (queues) perform poorly because of tombstones.
- **Names in sources:** query-driven modeling (Cassandra docs, DataStax); Chebotko method; wide partition pattern.
- **Sources:** Apache Cassandra, [Data modeling](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/index.html) (intro, rdbms, logical, physical, refining pages fetched); Chebotko, Kashlev, Lu, "A Big Data Modeling Methodology for Apache Cassandra", IEEE BigData Congress 2015, [author-uploaded copy](https://www.slideshare.net/slideshow/datamodelingpaper/49659552) (fetched; IEEE page blocked).

### hierarchical-partition-key

- **Situation:** A partition key (tenant) whose largest values outgrow one logical partition.
- **Structure:** Up to three key levels (`TenantId > UserId > SessionId`); prefix queries route to a subset of partitions.
- **Trade-offs:** Must be set at container creation; a low-cardinality first level hurts write throughput, in which case Microsoft suggests a synthetic key. Cosmos DB also names partition-key anti-patterns: `/id` for general workloads, low-cardinality fields, high cardinality unaligned with queries.
- **Sources:** Microsoft, [Hierarchical partition keys](https://learn.microsoft.com/en-us/azure/cosmos-db/hierarchical-partition-keys) and [Partitioning overview](https://learn.microsoft.com/en-us/azure/cosmos-db/partitioning-overview) (fetched).

## Schema evolution and database boundaries

### expand-contract

- **Situation:** A breaking schema change (rename, split, type change) in a system that cannot stop, with several application versions running at once.
- **Structure:** Three phases: expand (add the new structure alongside the old), migrate (backfill and dual-write while clients move), contract (remove the old structure). Ambler and Sadalage call the middle phase the transition period, kept in sync by trigger-based "database scaffolding code" with a published removal date; Fowler's evolutionary-database example renames a table and adds a view with the old name.
- **Trade-offs:** Zero-downtime and reversible at each step; temporary duplication and scaffolding code that must actually be removed.
- **Names in sources:** Parallel Change, a.k.a. expand and contract (Danilo Sato on martinfowler.com, 2014); transition period, deprecation period (Ambler; Sadalage and Schuh 2002); Schema Versioning Pattern (MongoDB, document-store analogue).
- **Sources:** Sato, [Parallel Change](https://martinfowler.com/bliki/ParallelChange.html) (fetched); Ambler, [Database Refactoring: The Process to Fix Production Databases](https://agiledata.org/?p=5090) (fetched).

### database-refactoring-catalog

- **Situation:** Small, behaviour- and information-preserving schema changes applied continuously.
- **Structure:** The Ambler–Sadalage catalog, *Refactoring Databases* (2006). The online catalog lists 70 entries in six groups: Architecture Refactoring (e.g. Add Mirror Table, Encapsulate Table With View, Introduce Read Only Table, Use Official Data Source), Structural Refactoring (e.g. Introduce Surrogate Key, Replace Surrogate Key With Natural Key, Merge Tables, Split Table, Split Column, Replace LOB With Table, Replace One-To-Many With Associative Tables), Data Quality Refactoring (e.g. Add Lookup Table, Apply Standard Codes, Consolidate Key Strategy, Replace Type Code With Property Flags), Referential Integrity Refactoring (Add Foreign Key Constraint, Introduce Cascading Delete, Introduce Hard Delete, Introduce Soft Delete, Introduce Trigger for History), Transformation, and Method Refactoring. Ambler moved Data Quality refactorings into a separate "data repair" practice in 2023 because they change data semantics.
- **Trade-offs:** Each refactoring changes schema, data and access code together; the catalog's value for this book is that many of its entries are the migration path *into* a pattern here (soft delete, history trigger, lookup table, surrogate key).
- **Sources:** [databaserefactoring.com](https://databaserefactoring.com/) (fetched; individual pages are stubs citing the book's page numbers); Ambler, [Database Refactoring Catalog](https://agiledata.org/essays/databaseRefactoringCatalog.html) and [Database Refactoring](https://agiledata.org/essays/databaseRefactoring.html) (fetched).

### evolutionary-database-design

- **Situation:** The schema must change as often as the code.
- **Structure (practice, not table shape):** Sadalage and Fowler's practices: all database artifacts version-controlled with code, all changes as migrations, everybody gets their own database instance, continuous integration of database changes, a database consists of schema and data, all changes as database refactorings, automate the refactorings, clearly separate database access code, release frequently.
- **Sources:** Sadalage and Fowler, [Evolutionary Database Design](https://martinfowler.com/articles/evodb.html), 2003, rewritten 2016 (fetched).

### edition-based-redefinition

- **Situation:** Online upgrade of database code and the visible table shape while the old application version is still running (Oracle).
- **Structure:** Editions (versioned namespaces for code objects), editioning views ("like an API for a table"), forward and reverse crossedition triggers that synchronize old and new columns; tables themselves are always noneditioned.
- **Trade-offs:** A native implementation of expand/contract with database-enforced isolation between versions; Oracle-specific and operationally complex.
- **Sources:** Oracle, [Using Edition-Based Redefinition](https://docs.oracle.com/en/database/oracle/oracle-database/19/adfns/editions.html) (fetched).

### encapsulate-table-with-view

- **Situation:** Decouple consumers from the physical table so it can be restructured.
- **Structure:** Clients read and write through views (or editioning views, or stored procedures) instead of base tables.
- **Sources:** Ambler/Sadalage "Encapsulate Table With View" ([databaserefactoring.com](https://databaserefactoring.com/), fetched); Oracle editioning views (above).

### application-vs-integration-database

- **Situation:** Deciding whether one database is shared by several applications or owned by one.
- **Structure:** Integration Database: one database "shared as the data store by several applications"; Application Database: a database "controlled and accessed by a single application", integration happening through APIs or messages; the microservices form is Database per Service versus Shared Database.
- **Trade-offs:** Fowler presents the integration database as a source of coupling that makes schema change hard; database-per-service moves joins and consistency into the application (sagas, CQRS, outbox).
- **Sources:** Fowler, [IntegrationDatabase](https://martinfowler.com/bliki/IntegrationDatabase.html), [ApplicationDatabase](https://martinfowler.com/bliki/ApplicationDatabase.html) (fetched); Chris Richardson, [Database per service](https://microservices.io/patterns/data/database-per-service.html) (options: private-tables-per-service, schema-per-service, database-server-per-service) and [Shared database](https://microservices.io/patterns/data/shared-database.html) (fetched).

## Classic data-model pattern catalogs

These books predate most vendor docs and are the closest thing the field has to a GoF catalog of *domain* structures (as opposed to the mechanical structures above). None of them is readable online; their tables of contents are, and Fowler has published a few supplementary papers. Entries below are named after the catalog idea, with the TOC as the verified citation; structural details are from the books and marked unverified.

### party-model

- **Situation:** People and organizations play the same roles (customer, supplier, employee, agent) and share contact data; separate `customers` and `suppliers` tables duplicate everything and cannot represent one company in two roles.
- **Structure:** Supertype `party` with subtypes `person` and `organization`; `party_role` (party, role type, from/to dates); `party_relationship` (from party/role, to party/role, type, dates); `contact_mechanism` reused through a party-contact junction.
- **Trade-offs:** Very flexible and history-friendly; generic and join-heavy, and easy to over-apply to simple systems. Silverston ch. 15 shows three physical options for party roles: separate tables per subtype, and a generic design (Figures 15.6–15.8).
- **Names in sources:** Party, Party Roles, Party Relationship, Party Contact Mechanism (Silverston Vol. 1 ch. 2); Party, Organization Hierarchies, Organization Structure, Accountability (Fowler *Analysis Patterns* ch. 2); Parties, Organizations, Reporting Relationships, Roles (Hay ch. 3, ch. 12).
- **Sources:** Silverston, [model list for The Data Model Resource Book Vol. 1 and 2](https://books.wiley.com/authors/len-silverston/models) (fetched; figure names verbatim); Fowler, [Analysis Patterns TOC](https://www.informit.com/store/analysis-patterns-reusable-object-models-9780134186054) (fetched); Hay, [Data Model Patterns: Conventions of Thought TOC](https://www.informit.com/store/data-model-patterns-conventions-of-thought-9780133492125) (fetched).

### accountability

- **Situation:** Organizational hierarchies that change over time and differ by purpose (reporting line, regional structure, sales territory).
- **Structure:** Instead of a `parent_id` on `organization`, an `accountability` link (commissioner party, responsible party, accountability type, time period); an "accountability knowledge level" holds the rules about which party types may be linked by which accountability types.
- **Trade-offs:** Represents multiple overlapping hierarchies and their history; requires a metadata layer to keep the generic links valid.
- **Names in sources:** Organization Hierarchies, Organization Structure, Accountability, Accountability Knowledge Level, Hierarchic Accountability, Operating Scopes, Post (Fowler AP ch. 2). Fowler's paper "Organization Structures (Accountability)" is online as a PDF.
- **Sources:** Fowler AP TOC (fetched); Fowler, [Organization Structures (Accountability)](https://martinfowler.com/apsupp/accountability.pdf) (listed on [martinfowler.com analysis-patterns tag](https://martinfowler.com/tags/analysis%20patterns.html), fetched; PDF not read).

### role-modeling

- **Situation:** One entity takes on several roles with partly shared, partly distinct data and behaviour, and roles change over its lifetime.
- **Structure options (Fowler's table of patterns):** Single Role Type (one type with all features), Separate Role Type (independent types), Role Subtype (subtype per role), Role Object (host object plus a separate object per role), Role Relationship (role as a relationship between two objects). In a schema these map to one wide table, independent tables, class-table inheritance, a `role` table keyed by host, and a relationship table respectively.
- **Trade-offs:** Fowler: the simple cases "are the simple cases, and often the right decision"; Role Object and Role Relationship are for when "the illusion" of a single multi-typed object is not worth it.
- **Sources:** Fowler, [Dealing with Roles](https://martinfowler.com/apsupp/roles.pdf), 1997 working draft (fetched; pattern table on pp. 2–3 read).

### dynamic-property

- **Situation:** Objects need properties that are numerous, vary per instance or must be added at run time.
- **Structure options (Fowler's table):** Fixed Property (a column); Dynamic Property; Flexible Dynamic Property (parameterized by a string, i.e. EAV); Defined Dynamic Property (parameter is an instance of a property-type entity); Typed Dynamic Property (property type also declares the value type); Separate Properties (each property an object so facts can be recorded about it); Typed Relationship (multi-valued properties as typed links); Dynamic Property Knowledge Level (rules about which kinds of object have which properties); Extrinsic Property (another object knows the property).
- **Trade-offs:** Fowler: Flexible Dynamic Property "makes it easy to define and use properties, but is difficult to control"; each step down the list buys control at the cost of more metadata. This is the most precise taxonomy of EAV variants found.
- **Sources:** Fowler, [Dealing with Properties](https://martinfowler.com/apsupp/properties.pdf), 1997 (fetched; pattern table on pp. 1–2 read).

### observation-and-measurement

- **Situation:** Recording facts about a subject that come with units, methods, times, and the possibility of being wrong (clinical data, lab results, sensor readings, KPIs).
- **Structure:** `observation` (subject, phenomenon type, protocol, recorded time, observed time, status) with a `measurement` subtype holding a `quantity` (amount + unit); rejected observations are kept and linked to their correction.
- **Trade-offs:** Generic and audit-friendly; queries for a specific measure need filtering by phenomenon type, similar to EAV.
- **Names in sources:** Quantity, Conversion Ratio, Compound Units, Measurement, Observation, Protocol, Dual Time Record, Rejected Observation, Active Observation, Hypothesis and Projection, Associated Observation (Fowler AP ch. 3); Samples, Tests and Observations (Hay ch. 8 "The Laboratory").
- **Sources:** Fowler AP TOC (fetched); Hay TOC (fetched); Fowler, [Quantity](https://martinfowler.com/eaaDev/Quantity.html) and [Range](https://martinfowler.com/eaaDev/Range.html) (listed on the tag page, fetched index).

### quantity-with-unit

- **Situation:** Amounts that are meaningless without a unit or currency.
- **Structure:** Store the amount and the unit (or currency) together, never a bare number; for money use exact decimal or minor-unit integers.
- **Names in sources:** Quantity (Fowler AP 3.1; eaaDev), Money (PoEAA base pattern), Rounding Errors (Karwin anti-pattern).
- **Sources:** Fowler [Quantity](https://martinfowler.com/eaaDev/Quantity.html); PoEAA [catalog](https://martinfowler.com/eaaCatalog/) (fetched).

### identification-scheme

- **Situation:** The same real-world object has several identifiers issued by different authorities (tax number, SKU, supplier part number), and duplicates must be merged.
- **Structure:** An `identifier` table (object, scheme, value) instead of one column per identifier; Object Merge and Object Equivalence record that two rows denote the same thing.
- **Names in sources:** Name, Identification Scheme, Object Merge, Object Equivalence (Fowler AP ch. 5); Product identification (Silverston Fig. 3.3).
- **Sources:** Fowler AP TOC (fetched); Silverston model list (fetched).

### bill-of-materials

- **Situation:** Products assembled from parts that are themselves products; a part can appear in many assemblies.
- **Structure:** A recursive many-to-many: `product_component(parent_product_id, component_product_id, quantity, from/to dates)`; traversed with recursive queries.
- **Trade-offs:** It is a DAG, not a tree, so nested sets and path enumeration do not fit; closure tables or recursive CTEs do.
- **Names in sources:** Product and parts, Product to product associations (Silverston Figs. 3.9–3.10); Bill of materials, Part Substitutions (Silverston Vol. 2 Figs. 2.6–2.7); Structure (Hay ch. 4); Material Requirements Planning (Hay ch. 9).
- **Sources:** Silverston model list (fetched); Hay TOC (fetched).

### agreement-and-order

- **Situation:** Commercial documents (quotes, orders, agreements, invoices, shipments) with header/line structure, roles, statuses, adjustments and terms.
- **Structure:** Header + item tables, a role table per document type (who ordered, who ships), status history, adjustment lines (tax, discount), and associations between items of different documents (order item to shipment item to invoice item).
- **Names in sources:** Orders and order items, Order status, Agreement item, Agreement terms, Agreement pricing (Silverston ch. 4); Shipment, Invoicing (ch. 5, 7); Contracts, Purchase Orders and Sales Orders (Hay ch. 6).
- **Sources:** Silverston model list (fetched); Hay TOC (fetched).

### thing-type-and-category

- **Situation:** Separating instances from their types and from user-defined classifications, so new kinds of things are data, not DDL.
- **Structure:** `thing` → `thing_type` (the knowledge level) plus a many-to-many to `category`; Fowler calls the type layer a knowledge level; it is the database form of the Type Object idea.
- **Trade-offs:** Flexibility versus losing typed columns; the step before EAV.
- **Names in sources:** Things, Thing Types and Categories; Heterogeneous Entities; Variable Length Records; "Usually One, Sometimes Many"; The Universal Data Model (Hay ch. 4, 12); Accountability Knowledge Level, Party Type Generalizations (Fowler AP ch. 2); Patterns for Type Models (Fowler AP ch. 14).
- **Sources:** Hay TOC (fetched); Fowler AP TOC (fetched).

### historic-mapping

- **Situation:** An association whose value changes over time and whose past values must be queryable (employee's department, price of a product).
- **Structure:** Fowler AP ch. 15: Associative Type (the link as an entity), Keyed Mapping (a map keyed by another object), Historic Mapping (a map keyed by time period). In a schema: a link table with `valid_from/valid_to`. See `effective-dating`.
- **Sources:** Fowler AP TOC (fetched).

### poeaa-structural-mappings

Fowler's *Patterns of Enterprise Application Architecture* (2002) "Object-Relational Structural Patterns" are the canonical names for several schema shapes in this inventory: Identity Field, Foreign Key Mapping, Association Table Mapping, Dependent Mapping, Embedded Value, Serialized LOB, Single Table Inheritance, Class Table Inheritance, Concrete Table Inheritance, Inheritance Mappers. Related groups: Offline Concurrency Patterns (Optimistic Offline Lock, Pessimistic Offline Lock, Coarse-Grained Lock, Implicit Lock), Session State (Database Session State), Base Patterns (Money, Value Object, Special Case). Source: [PoEAA catalog](https://martinfowler.com/eaaCatalog/) (fetched; the online entries are one-paragraph summaries, so trade-offs below come from the book's chapter 12 and are unverified online).

### celko-auxiliary-tables

- **Situation:** Computations that are easier as joins than as procedural code: calendars, business days, number sequences, lookup ranges.
- **Structure:** Static tables such as a calendar table (one row per date with fiscal period, holiday flag) or a numbers/sequence table.
- **Names in sources:** Auxiliary tables (Celko, who distinguishes them from base tables and staging tables); Date dimension (Kimball; see analytics section).
- **Sources:** Joe Celko, [Look-up Tables in SQL](https://www.red-gate.com/simple-talk/databases/sql-server/t-sql-programming-sql-server/look-up-tables-in-sql/) (fetched; defines auxiliary tables as "the relational replacement for computations", paraphrase).

## Anti-patterns

The anchor catalog is Bill Karwin's *SQL Antipatterns*. Its chapter list is identical in the 2010 first edition ([pragprog bksqla](https://pragprog.com/titles/bksqla/sql-antipatterns/), out of print) and the 2022 *Volume 1* ([pragprog bksap1](https://pragprog.com/titles/bksap1/sql-antipatterns-volume-1/)) except that the 2010 edition has "Magic Beans" where the 2022 edition has "Standard Operating Procedures" in the application section, and the 2022 edition adds a bonus "More Foreign Key Mini-Antipatterns" chapter was added (both TOCs fetched). Only the schema-structure chapters are listed in full here; query and application chapters are noted at the end. The problem/solution summaries come from Karwin's own [Practical Object-Oriented Models in SQL](https://www.slideshare.net/billkarwin/practical-object-oriented-models-in-sql) slides where they cover the chapter; otherwise they are from the book and marked unverified.

### jaywalking

- **Problem:** A comma-separated list of foreign IDs in one string column (`account_ids = '12,34'`) to avoid an intersection table.
- **Consequences:** No FK enforcement, no index use for membership, length limits, delimiter escaping, aggregation by string parsing.
- **Fix:** A junction table (`association-table`).
- **Sources:** Karwin, Logical Database Design Antipatterns, "Jaywalking" (TOC fetched; content unverified online).

### naive-trees

- **Problem:** Adjacency list queried with a fixed number of self-joins, so depth is capped and subtree operations need application loops.
- **Fix:** Recursive queries, path enumeration, nested sets or closure table, chosen by Karwin's comparison table (see the hierarchies section).
- **Sources:** Karwin, "Naive Trees" (TOC fetched); solutions and comparison from the slides (fetched).

### id-required

- **Problem:** Reflexively adding an `id` surrogate column to every table, including junction tables where the natural composite key is the right key; leads to duplicate pairs and confusing joins (`USING` breaks when every key is called `id`).
- **Fix:** Use natural or composite keys where they exist; name keys descriptively (`bug_id`).
- **Synonyms:** the "ID Required" chapter is the counterpart to Fowler's Identity Field, which *chooses* a surrogate key deliberately.
- **Sources:** Karwin, "ID Required" (TOC fetched; content from the book, unverified online).

### keyless-entry

- **Problem:** Omitting foreign key constraints "for flexibility" or performance, leaving integrity to application code.
- **Fix:** Declare FK constraints and use `ON DELETE/UPDATE` actions; PostgreSQL notes that declaring an FK does not create an index on the referencing columns, so add one.
- **Sources:** Karwin, "Keyless Entry" (TOC fetched); PostgreSQL, [Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html) (fetched).

### entity-attribute-value-antipattern

- **Problem:** A generic `(entity_id, attr_name, attr_value)` table to avoid schema changes.
- **Consequences (slides):** "Difficult to enforce mandatory attributes"; no data types, no FKs on values, reassembling a row needs one join per attribute.
- **Fix (slides):** Single Table Inheritance, Concrete Table Inheritance, Class Table Inheritance; the book also offers Serialized LOB / semi-structured data (unverified online).
- **Sources:** Karwin slides (fetched) and "Entity-Attribute-Value" chapter (TOC fetched). See `entity-attribute-value` for the pattern's legitimate uses.

### polymorphic-associations-antipattern

- **Problem:** `(parent_type, parent_id)` columns pointing at one of several tables, so no FK can be declared.
- **Fix (slides):** "Exclusive Arcs", "Reverse the relationship" (one intersection table per parent type), "Base parent table" (common super-table).
- **Sources:** Karwin slides (fetched), "Polymorphic Associations" chapter (TOC fetched). Rails and Django ship the shape as a feature (see `polymorphic-association`).

### multicolumn-attributes

- **Problem:** Repeating columns for a multi-valued attribute (`tag1`, `tag2`, `tag3`).
- **Consequences:** Search across N columns, arbitrary cap, duplicate values, schema change to add a slot.
- **Fix:** A dependent table, one row per value.
- **Sources:** Karwin, "Multicolumn Attributes" (TOC fetched; content unverified online). Classic 1NF "repeating group" violation.

### metadata-tribbles

- **Problem:** Cloning tables or columns by data value (`bugs_2008`, `bugs_2009`; `revenue_2024` column), so the schema grows with the data.
- **Fix:** Native partitioning (`horizontal-partitioning`) or a dependent table; Karwin's chapter also discusses horizontal and vertical partitioning as the proper tools (book, unverified online).
- **Sources:** Karwin, "Metadata Tribbles" (TOC fetched).

### rounding-errors

- **Problem:** `FLOAT`/`DOUBLE` for money or other exact quantities.
- **Fix:** `NUMERIC/DECIMAL`, or integer minor units; Fowler's Money pattern stores amount plus currency.
- **Sources:** Karwin, "Rounding Errors" (TOC fetched); Fowler, [Money](https://martinfowler.com/eaaCatalog/money.html) (PoEAA catalog, fetched index).

### thirty-one-flavors

- **Problem:** Restricting a column to a value list inside the column definition (`ENUM(...)` or a `CHECK ... IN (...)`), so changing the list is DDL and the list cannot be queried or extended with attributes.
- **Fix:** A lookup table with an FK (`lookup-table`).
- **Tension:** Conflicts with the `enum-type` pattern; PostgreSQL documents that enum values cannot be removed or reordered without recreating the type, which is exactly Karwin's complaint.
- **Sources:** Karwin, "31 Flavors" (TOC fetched); PostgreSQL, [Enumerated Types](https://www.postgresql.org/docs/current/datatype-enum.html) (fetched).

### phantom-files

- **Problem:** Storing only file paths in the database and the files on disk, so transactions, backups, deletes and access control do not cover the files.
- **Fix:** Store BLOBs, or accept external storage with explicit lifecycle handling.
- **Sources:** Karwin, "Phantom Files" (TOC fetched; content unverified online).

### index-shotgun

- **Problem:** Indexes added without measurement (none, too many, or useless ones).
- **Fix:** Karwin's "MENTOR" method (measure, explain, nominate, test, optimize, rebuild; book, unverified online).
- **Sources:** Karwin, "Index Shotgun" (TOC fetched). Physical rather than structural; probably out of scope for a schema-pattern book.

### pseudokey-neat-freak

- **Problem:** Renumbering surrogate keys to close gaps.
- **Fix:** Treat surrogate keys as meaningless; PostgreSQL documents that sequences are never gapless ("nextval and setval calls are never rolled back").
- **Sources:** Karwin, "Pseudokey Neat-Freak" (TOC fetched); PostgreSQL, [CREATE SEQUENCE](https://www.postgresql.org/docs/current/sql-createsequence.html) (fetched).

### readable-passwords

- **Problem:** Storing passwords in plain or reversibly encrypted columns.
- **Fix:** Salted slow hash column. Security more than structure.
- **Sources:** Karwin, "Readable Passwords" (TOC fetched).

### karwin-query-and-application-chapters

Not schema structure, listed for completeness: Fear of the Unknown (NULL), Ambiguous Groups, Random Selection, Poor Man's Search Engine, Spaghetti Query, Implicit Columns, SQL Injection, See No Evil, Diplomatic Immunity, Magic Beans (2010) / Standard Operating Procedures (2022), and the 2022 bonus "Foreign Key Mistakes in Standard SQL" / "in MySQL". Sources: both pragprog TOCs (fetched).

### one-true-lookup-table

- **Problem:** One generic code table `(code_type, code, description)` for every code list in the system.
- **Consequences:** FKs must include the type column or cannot be declared; a code of one domain can be used in another; all codes share the widest datatype; the table becomes a hot spot. Peterson argues the composite key creates a partial dependency, so the design cannot be normalized.
- **Fix:** One lookup table per domain.
- **Names in sources:** One True Lookup Table, OTLT (Celko credits Paul Keister with the phrase); Massively Unified Code-Key, MUCK (Don Peterson's coinage); Celko, *Thinking in Sets* §4.4 "OTLT or MUCK Table Problems".
- **Sources:** Don Peterson, [Lookup Table Madness](https://www.sqlservercentral.com/articles/lookup-table-madness), SQLServerCentral, 2004 (fetched; originator of "MUCK"); Joe Celko, [Look-up Tables in SQL](https://www.red-gate.com/simple-talk/databases/sql-server/t-sql-programming-sql-server/look-up-tables-in-sql/), Simple Talk, 2011 (fetched). Keister's original use of "OTLT" was not located (unverified).

### monolithic-persistence

- **Problem:** One data store for data with very different usage patterns (transactional rows, logs, telemetry, documents), so one workload degrades the others.
- **Fix:** Functional partitioning / polyglot persistence.
- **Sources:** Microsoft Azure Architecture Center, [Antipatterns](https://learn.microsoft.com/en-us/azure/architecture/antipatterns/) catalog: "Monolithic Persistence" (index fetched; detail page not fetched). The same catalog lists "Busy Database" (too much processing in the data store) and "Noisy Neighbor" (one tenant consumes disproportionate resources), which matters for `shared-schema-tenancy`.

### document-store-antipatterns

MongoDB's manual lists exactly five [schema design anti-patterns](https://www.mongodb.com/docs/manual/data-modeling/design-antipatterns/) (fetched): Avoid Unbounded Arrays, Reduce Number of Collections, Remove Unnecessary Indexes, Reduce Bloated Documents, Reduce $lookup Operations (fix: embed needed fields with the subset pattern, minding "document size limitations and data duplication"). The older Developer Center list also had "case-insensitive queries without case-insensitive indexes" and "separating data that is accessed together"; those pages now return 404 (unverified). Relational counterparts: unbounded arrays ≈ unbounded JSON documents (PostgreSQL warns that updates lock the whole row); too many collections ≈ "Metadata Tribbles"; $lookup everywhere ≈ normalizing data that is always read together.

### table-based-tenant-isolation

- **Problem:** A separate copy of every table per tenant inside one database (`orders_tenant42`).
- **Consequences:** Schema-change fan-out, catalog bloat, no shared indexes or plans; it is Metadata Tribbles applied to tenants.
- **Sources:** Microsoft, [Architectural approaches for storage and data in multitenant solutions](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/approaches/storage-data) (fetched), which lists "Table-based isolation", "Column-level tenant customization", "Manual schema changes" and "Version dependencies" as antipatterns.

### bad-partition-key

- **Problem:** A partition or shard key with low cardinality, skewed access or no alignment with queries (first letter of a name, a status flag, `/id` for workloads that query by something else).
- **Consequences:** Hot partitions, scatter-gather queries, expensive re-sharding because the key "can be difficult to change".
- **Sources:** Microsoft, [Azure Cosmos DB partitioning overview](https://learn.microsoft.com/en-us/azure/cosmos-db/partitioning-overview) ("Common partition key anti-patterns") and [data partitioning recommendations](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/partition-data) (fetched); AWS [write sharding](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-sharding.html) (fetched).

### centipede-fact-table

- **Problem:** Normalizing every dimension hierarchy level into its own FK on the fact table, producing dozens of dimension keys.
- **Sources:** Kimball [technique index](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/) lists "Centipede fact table" under advanced fact table techniques (index fetched; page content not fetched, so the description here is unverified).

### integration-database

- **Problem:** Several applications share one database as their integration mechanism, so every schema change needs coordination across teams.
- **Sources:** Fowler, [IntegrationDatabase](https://martinfowler.com/bliki/IntegrationDatabase.html) (fetched; Fowler frames it as a pattern with heavy costs rather than labelling it an anti-pattern); Chris Richardson, [Shared database](https://microservices.io/patterns/data/shared-database.html) (fetched; drawbacks: schema-change coupling and runtime lock contention).

## Overlap and dedup map

Each row is one idea under the names different sources give it. A dash means the source has no named counterpart. "Karwin" is *SQL Antipatterns*; "PoEAA" and "AP" are Fowler's *Patterns of Enterprise Application Architecture* and *Analysis Patterns*.

| Idea (proposed slug) | Fowler | Karwin | Ambler / Sadalage | ORMs | Vendors / other catalogs |
|---|---|---|---|---|---|
| `single-table-inheritance` | Single Table Inheritance (PoEAA) | alternative to EAV | Map Hierarchy To A Single Table | Rails STI; Hibernate SINGLE_TABLE; Django proxy (no new columns) | MongoDB Polymorphic / Inheritance Pattern; Kimball supertype schemas (core table) |
| `class-table-inheritance` | Class Table Inheritance (PoEAA); Role Subtype (Roles paper) | alternative to EAV; "Base parent table" for polymorphic associations | Map Each Class To Its Own Table | Hibernate JOINED; Django multi-table; Rails Delegated Types | Kimball supertype/subtype schemas; Silverston party-role "separate tables for sub-types" |
| `concrete-table-inheritance` | Concrete Table Inheritance (PoEAA) | alternative to EAV | Map Each Concrete Class To Its Own Table | Hibernate TABLE_PER_CLASS; Django abstract base; @MappedSuperclass | — |
| `polymorphic-association` | — | Polymorphic Associations (anti-pattern) | — | Rails polymorphic; Django GenericForeignKey | — |
| `exclusive-arc` | — | Exclusive Arcs | — | — | Barker CASE*Method exclusive arc (unverified) |
| `shared-supertype` | Role Object / Party (AP) | Base parent table | — | Rails Delegated Types | Silverston Party; Hay Parties |
| `entity-attribute-value` | Flexible / Defined / Typed Dynamic Property (Properties paper) | Entity-Attribute-Value (anti-pattern) | Map Classes To A Generic Table Structure | — | MongoDB Attribute Pattern; MariaDB EAV article; SQL Server sparse columns as replacement |
| `json-column` | Serialized LOB (PoEAA) | (book's EAV alternative, unverified) | Replace LOB With Table (reverse direction) | — | PostgreSQL jsonb; MySQL JSON + generated columns; Microsoft "inheritance with JSON" |
| `lookup-table` | — | fix for 31 Flavors | Add Lookup Table, Apply Standard Codes | — | Celko look-up tables; Citus reference tables; Kimball dimensions |
| `one-true-lookup-table` | — | — | — | — | OTLT (Keister via Celko); MUCK (Peterson) |
| `adjacency-list` | — | Adjacency List / Naive Trees | Recursive Relationships | — | Celko adjacency list; MongoDB Parent References; DynamoDB adjacency list (graph edges, different meaning) |
| `path-enumeration` | — | Path Enumeration | — | — | Celko path enumeration; MongoDB Materialized Paths / Array of Ancestors / Tree Pattern; PostgreSQL ltree; SQL Server hierarchyid; DynamoDB composite sort key; Kimball pathstring |
| `closure-table` | — | Closure Table | — | — | Kimball hierarchy bridge table; transitive closure |
| `nested-sets` | — | Nested Sets | — | — | Celko nested sets; MongoDB Nested Sets |
| `association-table` | Association Table Mapping (PoEAA); Associative Type (AP) | intersection table (fix for Jaywalking) | Replace One-To-Many With Associative Tables | Rails has_many :through / HABTM | Kimball bridge table (multivalued) |
| `effective-dating` | Effectivity, Temporal Property, Historic Mapping, Range | — | — | — | SQL:2011 application-time period; Db2 application-period; Oracle Temporal Validity; PostgreSQL 18 WITHOUT OVERLAPS |
| `system-versioned-table` | Temporal Object; record time (Bitemporal History) | — | Introduce Trigger for History | — | SQL:2011 system-versioned; SQL Server temporal; MariaDB; Db2 system-period; Oracle Flashback Time Travel; Kimball SCD Type 2 (warehouse form); MongoDB Document Versioning; DynamoDB sort-key version control |
| `audit-log` | Audit Log | — | Introduce Trigger for History | — | SQL Server ledger tables (tamper-evident form) |
| `soft-delete` | — | — | Introduce Soft Delete / Introduce Hard Delete | Laravel SoftDeletes; Hibernate @SoftDelete; Rails discard | Brandur's deleted-record table (alternative) |
| `event-sourcing` | Event Sourcing | — | — | — | microservices.io; Azure Event Sourcing pattern |
| `double-entry-ledger` | Account, Accounting Entry, Accounting Transaction (eaaDev); Inventory and Accounting (AP ch. 6) | — | — | — | Silverston accounting transactions; Hay Accounting; Square Books; Modern Treasury; TigerBeetle |
| `summary-table` | Summary Account (AP) | — | Introduce Calculated Column | Rails counter_cache | MongoDB Computed / Bucket; Kimball aggregated facts; Azure Materialized View pattern; PostgreSQL materialized views |
| `version-column` | Optimistic Offline Lock (PoEAA) | — | — | Rails lock_version; JPA @Version | SQL Server rowversion |
| `surrogate-key` | Identity Field (PoEAA) | ID Required (when overused) | Introduce Surrogate Key | — | Kimball dimension surrogate keys |
| `hi-lo-allocation` | — | — | HIGH-LOW (Ambler keys essay) | Hibernate hilo → pooled / pooled-lo | PostgreSQL sequence CACHE |
| `horizontal-partitioning` | — | fix for Metadata Tribbles | — | — | PostgreSQL / MySQL / SQL Server / Oracle partitioning; DynamoDB table-per-period (manual form) |
| `sharding` | — | — | — | — | Azure Sharding pattern; Citus distribution column; DynamoDB / Cosmos DB partition key; AWS pool model |
| `vertical-partitioning` | — | — | Split Table | — | Azure vertical partitioning; DynamoDB vertical partitioning; MongoDB Subset Pattern |
| `extended-reference-pattern` | — | — | Add Mirror Table (closest) | — | MongoDB Extended Reference; Cosmos DB hybrid model; Kimball denormalized dimensions |
| `single-table-design` | — | — | — | — | DynamoDB single-table; MongoDB Single Collection Pattern; Cassandra one-table-per-query (opposite direction: duplicate rather than co-locate) |
| `expand-contract` | Parallel Change (Sato); transition phase (evodb) | — | transition period | — | MongoDB Schema Versioning; Oracle Edition-Based Redefinition |
| `party-model` | Party, Accountability (AP) | — | — | — | Silverston Party / Roles / Relationships; Hay Parties |
| `shared-schema-tenancy` | — | — | — | — | AWS pool; Azure multitenant database; Citus row-based sharding |
| `schema-per-tenant` | — | — | — | — | AWS bridge; Citus schema-based sharding; microservices.io schema-per-service |
| `database-per-tenant` | — | — | — | — | AWS silo; Azure database-per-tenant; Deployment Stamps |

## Chapter-candidate assessment

Strongest chapter candidates (editorial ranking: a clear problem, a choice between documented alternatives, primary sources available, and relevance to everyday application work):

1. `closure-table`, framed as the trees chapter with adjacency list, path enumeration and nested sets as variants. Karwin's comparison table, Celko, ltree, hierarchyid and MongoDB give one of the best-sourced trade-off matrices in the field (two cells of Karwin's table still need checking against the slide images).
2. `effective-dating`: application-time periods with no-overlap constraints. SQL:2011, PostgreSQL 18 `WITHOUT OVERLAPS`/`PERIOD`, MariaDB, Db2 and Oracle all implement it; Fowler's Effectivity names it.
3. `system-versioned-table` / `history-table`, paired with `audit-log` and contrasted with `bitemporal-table`.
4. `class-table-inheritance`, with single-table and concrete-table inheritance as siblings. Fowler, Ambler, Hibernate, Django and Rails Delegated Types make it a natural GoF-style trio.
5. `polymorphic-association`, with `exclusive-arc` and `shared-supertype` as the fixes. The Rails/Django-versus-Karwin tension makes a strong teaching chapter.
6. `double-entry-ledger`, with `derived-balance`. Fowler, Silverston, Square, Modern Treasury and TigerBeetle agree on the invariant and differ instructively on balances.
7. `soft-delete`, with the deleted-record archive alternative. Very common, with sharp sourced disagreement.
8. `transactional-outbox`, with `processed-messages-table` and `idempotency-key-table`: the schema side of reliable messaging.
9. `json-column`, positioned against `entity-attribute-value` and `sparse-columns`. Fowler's property taxonomy and the PostgreSQL design advice give it depth.
10. `shared-schema-tenancy`, with schema-per-tenant, database-per-tenant and row-level security as alternatives. Three vendor vocabularies map cleanly onto each other.

Close runners-up: `lookup-table` versus `enum-type` versus `check-constraint-domain` (one "reference data" chapter); `queue-table`; `expand-contract`; `star-schema` with `slowly-changing-dimension`; `time-ordered-identifier`; `horizontal-partitioning`; `party-model`; `single-table-design`.

Weak as standalone chapters (better as variants or sidebars): `postgresql-table-inheritance`, `preallocation-pattern`, `nested-intervals`, `unlogged-staging-table`, `key-value-column` (hstore), `generic-table-structure`, `tenant-customization`, `table-per-period`, `index-shotgun`, `readable-passwords`.

## Gaps and verification limits

- **Books readable only by table of contents:** Karwin (beyond his slides), Hay, Silverston, Celko, Fowler's *Analysis Patterns* and PoEAA chapter 12, Ambler and Sadalage's *Refactoring Databases*. Names are verified; structural details attributed to them need checking against the text before a chapter cites them.
- **Data Vault 2.0:** the Data Vault Alliance site publishes no definitions. Only Linstedt's 2002 hub/link/satellite overview was citable. PIT, bridge, same-as and hierarchical links, and effectivity and multi-active satellites are unverified against a primary source.
- **Unreachable originators:** Twitter's Snowflake announcement (403; the GitHub README was used), Instagram's "Sharding & IDs at Instagram", Craig Ringer's SKIP LOCKED post, MongoDB's standalone Polymorphic Pattern post and its old anti-pattern articles, the IEEE page of the Chebotko paper (an author copy was used), and the ISO SQL/PGQ record (403; paywalled anyway).
- **No primary source found:** the name "One Big Table", Paul Keister's original OTLT usage, the status-transition-table FK technique, the internal/external key split as a named pattern, and the session-variable RLS tenancy idiom.
- **Version facts not confirmed on the pages fetched:** MariaDB temporal introduction versions, Oracle EBR (11.2) and Temporal Validity (12c), Db2 `BUSINESS_TIME WITHOUT OVERLAPS`.

## Sources consulted

Every URL cited above, grouped by host. The fetch status of each is given where it is cited.

### agiledata.org

- [Database Refactoring: The Process to Fix Production Databases](https://agiledata.org/?p=5090)
- [Database Refactoring](https://agiledata.org/essays/databaseRefactoring.html)
- [Database Refactoring Catalog](https://agiledata.org/essays/databaseRefactoringCatalog.html)
- [Choosing a Primary Key: Natural or Surrogate?](https://agiledata.org/essays/keys.html)
- [Mapping Objects to Relational Databases](https://agiledata.org/essays/mappingObjects.html)

### anchormodeling.com

- [anchormodeling.com/about](https://www.anchormodeling.com/about/)
- [author preprint](https://www.anchormodeling.com/wp-content/uploads/2011/05/Anchor-Modeling.pdf)

### api.rubyonrails.org

- [DelegatedType API](https://api.rubyonrails.org/classes/ActiveRecord/DelegatedType.html)
- [Locking::Optimistic](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Optimistic.html)

### arxiv.org

- [Nested Intervals Tree Encoding with Continued Fractions](https://arxiv.org/abs/cs/0402051)

### aws.amazon.com

- [Single-table vs. multi-table design in Amazon DynamoDB](https://aws.amazon.com/blogs/database/single-table-vs-multi-table-design-in-amazon-dynamodb/)

### books.wiley.com

- [model list](https://books.wiley.com/authors/len-silverston/models)

### brandur.org

- [Implementing Stripe-like Idempotency Keys in Postgres](https://brandur.org/idempotency-keys)
- [Soft Deletion Probably Isn't Worth It](https://brandur.org/soft-deletion)

### cassandra.apache.org

- [logical data modeling](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/data-modeling_logical.html)
- [Data modeling](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/index.html)
- [intro](https://cassandra.apache.org/doc/latest/cassandra/developing/data-modeling/intro.html)

### databaserefactoring.com

- [databaserefactoring.com](https://databaserefactoring.com/)

### datavaultalliance.com

- [datavaultalliance.com](https://datavaultalliance.com/)

### dataversity.net

- [Data Vault Series 1 – Data Vault Overview](https://www.dataversity.net/articles/data-vault-series-1-data-vault-overview/)

### debezium.io

- [Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html)

### dev.mysql.com

- [CREATE INDEX (multi-valued indexes)](https://dev.mysql.com/doc/refman/8.4/en/create-index.html)
- [Generated Columns](https://dev.mysql.com/doc/refman/8.4/en/create-table-generated-columns.html)
- [Clustered and Secondary Indexes](https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html)
- [The JSON Data Type](https://dev.mysql.com/doc/refman/8.4/en/json.html)
- [Partitioning Keys, Primary Keys, and Unique Keys](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-partitioning-keys-unique-keys.html)
- [Partitioning Limitations Relating to Storage Engines](https://dev.mysql.com/doc/refman/8.4/en/partitioning-limitations-storage-engines.html)
- [Partitioning Types](https://dev.mysql.com/doc/refman/8.4/en/partitioning-types.html)

### dev.to

- [Designing APIs for humans: Object IDs](https://dev.to/stripe/designing-apis-for-humans-object-ids-3o5a)

### developer.squareup.com

- [Books, an immutable double-entry accounting database service](https://developer.squareup.com/blog/books-an-immutable-double-entry-accounting-database-service/)

### docs.aws.amazon.com

- [Best practices for managing many-to-many relationships](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-adjacency-graphs.html)
- [NoSQL design](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html)
- [Overloading Global Secondary Indexes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-gsi-overloading.html)
- [sparse indexes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes-general-sparse-indexes.html)
- [Using write sharding](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-partition-key-sharding.html)
- [Best practices for using sort keys](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-sort-keys.html)
- [Best practices for handling time series data](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-time-series.html)
- [Best practices for storing large items and attributes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-use-s3-too.html)
- [Data modeling building blocks](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/data-modeling-blocks.html)
- [Data modeling foundations in DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/data-modeling-foundations.html)
- [SaaS Storage Strategies (PDF, 2021, historical)](https://docs.aws.amazon.com/pdfs/whitepapers/latest/multi-tenant-saas-storage-strategies/multi-tenant-saas-storage-strategies.pdf)
- [SaaS Architecture Fundamentals: Data partitioning](https://docs.aws.amazon.com/whitepapers/latest/saas-architecture-fundamentals/data-partitioning.html)

### docs.citusdata.com

- [Concepts](https://docs.citusdata.com/en/stable/get_started/concepts.html)
- [Choosing Distribution Column](https://docs.citusdata.com/en/stable/sharding/data_modeling.html)
- [Multi-tenant Applications](https://docs.citusdata.com/en/stable/use_cases/multi_tenant.html)

### docs.cloud.google.com

- [Use nested and repeated fields](https://docs.cloud.google.com/bigquery/docs/best-practices-performance-nested)

### docs.djangoproject.com

- [contenttypes framework](https://docs.djangoproject.com/en/5.2/ref/contrib/contenttypes/)
- [model inheritance](https://docs.djangoproject.com/en/5.2/topics/db/models/)

### docs.getdbt.com

- [Marts](https://docs.getdbt.com/best-practices/how-we-structure/4-marts)

### docs.hibernate.org

- [User Guide 6.6](https://docs.hibernate.org/orm/6.6/userguide/html_single/Hibernate_User_Guide.html)
- [7.0](https://docs.hibernate.org/orm/7.0/userguide/html_single/Hibernate_User_Guide.html)

### docs.moderntreasury.com

- [Ledger Transaction object](https://docs.moderntreasury.com/ledgers/reference/ledger-transaction-object)

### docs.oracle.com

- [Using Edition-Based Redefinition](https://docs.oracle.com/en/database/oracle/oracle-database/19/adfns/editions.html)
- [Partitioning Concepts](https://docs.oracle.com/en/database/oracle/oracle-database/19/vldbg/partition-concepts.html)
- [Design basics: Temporal Validity](https://docs.oracle.com/en/database/oracle/oracle-database/21/adfns/design_basics.html)
- [Using Flashback Technology](https://docs.oracle.com/en/database/oracle/oracle-database/21/adfns/flashback.html)
- [Workspace Manager valid time](https://docs.oracle.com/en/database/oracle/oracle-database/26/adwsm/valid-time-support-introduction-and-example.html)

### docs.stripe.com

- [API versioning: compatible changes](https://docs.stripe.com/api-versions)
- [Idempotent requests](https://docs.stripe.com/api/idempotent_requests)

### docs.tigerbeetle.com

- [Data modeling](https://docs.tigerbeetle.com/coding/data-modeling/)
- [Account](https://docs.tigerbeetle.com/reference/account/)
- [Transfer](https://docs.tigerbeetle.com/reference/transfer/)

### doi.org

- [DOI 10.1016/j.datak.2010.10.002](https://doi.org/10.1016/j.datak.2010.10.002)

### fivetran.com

- [Data warehouse modeling: Star schema vs. OBT](https://www.fivetran.com/blog/star-schema-vs-obt)

### github.com

- [GoodJob README](https://github.com/bensheldon/good_job)
- [discard README](https://github.com/jhawthorn/discard)
- [Solid Queue README](https://github.com/rails/solid_queue)
- [twitter-archive/snowflake (2010 branch README)](https://github.com/twitter-archive/snowflake/tree/snowflake-2010)
- [ULID spec](https://github.com/ulid/spec)

### guides.rubyonrails.org

- [6.1 release notes](https://guides.rubyonrails.org/6_1_release_notes.html)
- [Rails association guide](https://guides.rubyonrails.org/association_basics.html)

### ibm.com

- [Application-period temporal tables](https://www.ibm.com/docs/en/db2/11.5.x?topic=tables-application-period-temporal)
- [System-period temporal tables](https://www.ibm.com/docs/en/db2/11.5.x?topic=tables-system-period-temporal)

### informit.com

- [TOC](https://www.informit.com/store/analysis-patterns-reusable-object-models-9780134186054)
- [TOC](https://www.informit.com/store/data-model-patterns-conventions-of-thought-9780133492125)

### iso.org

- [ISO/IEC 9075-16:2023 SQL/PGQ](https://www.iso.org/standard/79473.html)

### kimballgroup.com

- [technique index](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/)
- [Accumulating Snapshot Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/accumulating-snapshot-fact-table/)
- [Audit Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/audit-dimension/)
- [Conformed Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/conformed-dimension/)
- [Degenerate Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/degenerate-dimension/)
- [Factless Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/factless-fact-table/)
- [Junk Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/junk-dimension/)
- [Multivalued Dimensions and Bridge Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/multivalued-dimension-bridge-table/)
- [Outrigger Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/outrigger-dimension/)
- [Periodic Snapshot Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/periodic-snapshot-fact-table/)
- [Ragged/Variable Depth Hierarchies](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/ragged-variable-depth-hierarchy/)
- [Role-Playing Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/role-playing-dimension/)
- [Snowflaked Dimensions](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/snowflake-dimension/)
- [Star Schemas and OLAP Cubes](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/star-schema-olap-cube/)
- [Transaction Fact Tables](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/transaction-fact-table/)
- [Type 0](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-0/)
- [Type 1](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-1/)
- [Type 2](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-2/)
- [Type 3](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-3/)
- [Type 4](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-4-mini-dimension/)
- [Type 5](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-5/)
- [Type 6](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-6/)
- [Type 7](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/type-7/)

### laravel.com

- [Eloquent: Soft Deleting](https://laravel.com/docs/12.x/eloquent#soft-deleting)

### learn.microsoft.com

- [A conversation about how to implement name/value pairs](https://learn.microsoft.com/en-us/archive/blogs/qingsongyao/a-conversation-about-how-to-implement-namevalue-pairs)
- [Inheritance with JSON](https://learn.microsoft.com/en-us/archive/blogs/sqlserverstorageengine/inheritance-with-json)
- [Antipatterns](https://learn.microsoft.com/en-us/azure/architecture/antipatterns/)
- [Architectural approaches for storage and data in multitenant solutions](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/approaches/storage-data)
- [CQRS pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/cqrs)
- [Event Sourcing pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing)
- [Idempotent Consumer pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/idempotent-consumer)
- [Index Table pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/index-table)
- [Materialized View pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/materialized-view)
- [Sharding pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/sharding)
- [Multitenant SaaS patterns](https://learn.microsoft.com/en-us/azure/azure-sql/database/saas-tenancy-app-design-patterns)
- [Hierarchical partition keys](https://learn.microsoft.com/en-us/azure/cosmos-db/hierarchical-partition-keys)
- [Azure Cosmos DB data modeling](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/modeling-data)
- [Partitioning overview](https://learn.microsoft.com/en-us/azure/cosmos-db/partitioning-overview)
- [data partitioning recommendations](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/partition-data)
- [SQL Graph overview](https://learn.microsoft.com/en-us/sql/relational-databases/graphs/sql-graph-overview)
- [Hierarchical data (SQL Server)](https://learn.microsoft.com/en-us/sql/relational-databases/hierarchical-data-sql-server)
- [Partitioned tables and indexes](https://learn.microsoft.com/en-us/sql/relational-databases/partitions/partitioned-tables-and-indexes)
- [Ledger limitations](https://learn.microsoft.com/en-us/sql/relational-databases/security/ledger/ledger-limits)
- [Ledger overview](https://learn.microsoft.com/en-us/sql/relational-databases/security/ledger/ledger-overview)
- [considerations and limitations](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-table-considerations-and-limitations)
- [Temporal tables](https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables)
- [Use column sets](https://learn.microsoft.com/en-us/sql/relational-databases/tables/use-column-sets)
- [Use sparse columns](https://learn.microsoft.com/en-us/sql/relational-databases/tables/use-sparse-columns)
- [rowversion](https://learn.microsoft.com/en-us/sql/t-sql/data-types/rowversion-transact-sql)
- [CREATE VIEW: partitioned views](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-view-transact-sql)

### mariadb.com

- [Entity-Attribute-Value Implementation](https://mariadb.com/docs/server-1/ha-and-performance/optimization-and-tuning/optimizing-tables/entity-attribute-value-implementation)
- [System-versioned tables](https://mariadb.com/docs/server/reference/sql-structure/temporal-tables/system-versioned-tables)
- [Application-time periods](https://mariadb.com/kb/en/application-time-periods/)
- [Bitemporal tables](https://mariadb.com/kb/en/bitemporal-tables/)

### martinfowler.com

- [Organization Structures (Accountability)](https://martinfowler.com/apsupp/accountability.pdf)
- [Dealing with Properties](https://martinfowler.com/apsupp/properties.pdf)
- [Dealing with Roles](https://martinfowler.com/apsupp/roles.pdf)
- [Bitemporal History](https://martinfowler.com/articles/bitemporal-history.html)
- [Evolutionary Database Design](https://martinfowler.com/articles/evodb.html)
- [ApplicationDatabase](https://martinfowler.com/bliki/ApplicationDatabase.html)
- [CQRS](https://martinfowler.com/bliki/CQRS.html)
- [IntegrationDatabase](https://martinfowler.com/bliki/IntegrationDatabase.html)
- [Parallel Change](https://martinfowler.com/bliki/ParallelChange.html)
- [ReportingDatabase](https://martinfowler.com/bliki/ReportingDatabase.html)
- [catalog](https://martinfowler.com/eaaCatalog/)
- [Association Table Mapping](https://martinfowler.com/eaaCatalog/associationTableMapping.html)
- [Class Table Inheritance](https://martinfowler.com/eaaCatalog/classTableInheritance.html)
- [Concrete Table Inheritance](https://martinfowler.com/eaaCatalog/concreteTableInheritance.html)
- [Dependent Mapping](https://martinfowler.com/eaaCatalog/dependentMapping.html)
- [Embedded Value](https://martinfowler.com/eaaCatalog/embeddedValue.html)
- [Foreign Key Mapping](https://martinfowler.com/eaaCatalog/foreignKeyMapping.html)
- [Identity Field](https://martinfowler.com/eaaCatalog/identityField.html)
- [Money](https://martinfowler.com/eaaCatalog/money.html)
- [Optimistic Offline Lock](https://martinfowler.com/eaaCatalog/optimisticOfflineLock.html)
- [Pessimistic Offline Lock](https://martinfowler.com/eaaCatalog/pessimisticOfflineLock.html)
- [Serialized LOB](https://martinfowler.com/eaaCatalog/serializedLOB.html)
- [Single Table Inheritance](https://martinfowler.com/eaaCatalog/singleTableInheritance.html)
- [Account](https://martinfowler.com/eaaDev/Account.html)
- [Accounting Entry](https://martinfowler.com/eaaDev/AccountingEntry.html)
- [Patterns for Accounting](https://martinfowler.com/eaaDev/AccountingNarrative.html)
- [Accounting Transaction](https://martinfowler.com/eaaDev/AccountingTransaction.html)
- [Audit Log](https://martinfowler.com/eaaDev/AuditLog.html)
- [Effectivity](https://martinfowler.com/eaaDev/Effectivity.html)
- [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)
- [Quantity](https://martinfowler.com/eaaDev/Quantity.html)
- [Range](https://martinfowler.com/eaaDev/Range.html)
- [Snapshot](https://martinfowler.com/eaaDev/Snapshot.html)
- [Temporal Object](https://martinfowler.com/eaaDev/TemporalObject.html)
- [Temporal Property](https://martinfowler.com/eaaDev/TemporalProperty.html)
- [Temporal Patterns](https://martinfowler.com/eaaDev/timeNarrative.html)
- [martinfowler.com analysis-patterns tag](https://martinfowler.com/tags/analysis%20patterns.html)

### microservices.io

- [Idempotent Consumer](https://microservices.io/patterns/communication-style/idempotent-consumer.html)
- [CQRS](https://microservices.io/patterns/data/cqrs.html)
- [Database per service](https://microservices.io/patterns/data/database-per-service.html)
- [Event sourcing](https://microservices.io/patterns/data/event-sourcing.html)
- [Polling publisher](https://microservices.io/patterns/data/polling-publisher.html)
- [Saga](https://microservices.io/patterns/data/saga.html)
- [Shared database](https://microservices.io/patterns/data/shared-database.html)
- [Transaction log tailing](https://microservices.io/patterns/data/transaction-log-tailing.html)
- [Transactional outbox](https://microservices.io/patterns/data/transactional-outbox.html)

### mongodb.com

- [summary](https://www.mongodb.com/company/blog/building-with-patterns-a-summary)
- [The Approximation Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-approximation-pattern)
- [The Attribute Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-attribute-pattern)
- [The Bucket Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-bucket-pattern)
- [The Computed Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-computed-pattern)
- [The Document Versioning Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-document-versioning-pattern)
- [The Extended Reference Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-extended-reference-pattern)
- [The Outlier Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-outlier-pattern)
- [The Preallocation Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-preallocation-pattern)
- [The Schema Versioning Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-schema-versioning-pattern)
- [The Subset Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-subset-pattern)
- [The Tree Pattern](https://www.mongodb.com/company/blog/building-with-patterns-the-tree-pattern)
- [Model Tree Structures](https://www.mongodb.com/docs/manual/applications/data-models-tree-structures/)
- [Schema Validation](https://www.mongodb.com/docs/manual/core/schema-validation/)
- [Best Practices for Data Modeling](https://www.mongodb.com/docs/manual/data-modeling/best-practices/)
- [schema design anti-patterns](https://www.mongodb.com/docs/manual/data-modeling/design-antipatterns/)
- [Schema Design Patterns](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/)
- [Archive Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/archive/)
- [Computed Data](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/computed-values/computed-schema-pattern/)
- [Attribute Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/attribute-pattern/)
- [Bucket Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/bucket-pattern/)
- [Outlier Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/outlier-pattern/)
- [Subset Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/group-data/subset-pattern/)
- [Polymorphic Data](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/polymorphic-data/)
- [Single Collection Pattern](https://www.mongodb.com/docs/manual/data-modeling/design-patterns/single-collection/)

### postgresql.org

- [btree_gist](https://www.postgresql.org/docs/current/btree-gist.html)
- [Enumerated Types](https://www.postgresql.org/docs/current/datatype-enum.html)
- [JSON Types](https://www.postgresql.org/docs/current/datatype-json.html)
- [Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
- [Generated Columns](https://www.postgresql.org/docs/current/ddl-generated-columns.html)
- [Identity Columns](https://www.postgresql.org/docs/current/ddl-identity-columns.html)
- [Inheritance](https://www.postgresql.org/docs/current/ddl-inherit.html)
- [Table Partitioning](https://www.postgresql.org/docs/current/ddl-partitioning.html)
- [Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [Schemas](https://www.postgresql.org/docs/current/ddl-schemas.html)
- [UUID Functions](https://www.postgresql.org/docs/current/functions-uuid.html)
- [hstore](https://www.postgresql.org/docs/current/hstore.html)
- [ltree](https://www.postgresql.org/docs/current/ltree.html)
- [WITH Queries](https://www.postgresql.org/docs/current/queries-with.html)
- [Range Types](https://www.postgresql.org/docs/current/rangetypes.html)
- [Materialized Views](https://www.postgresql.org/docs/current/rules-materializedviews.html)
- [ALTER TYPE](https://www.postgresql.org/docs/current/sql-altertype.html)
- [CREATE DOMAIN](https://www.postgresql.org/docs/current/sql-createdomain.html)
- [CREATE SEQUENCE](https://www.postgresql.org/docs/current/sql-createsequence.html)
- [CREATE TABLE](https://www.postgresql.org/docs/current/sql-createtable.html)
- [REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/current/sql-refreshmaterializedview.html)
- [SELECT: The Locking Clause](https://www.postgresql.org/docs/current/sql-select.html)
- [TOAST](https://www.postgresql.org/docs/current/storage-toast.html)
- [Release 18](https://www.postgresql.org/docs/release/18.0/)

### pragprog.com

- [SQL Antipatterns Vol. 1](https://pragprog.com/titles/bksap1/sql-antipatterns-volume-1/)
- [pragprog bksqla](https://pragprog.com/titles/bksqla/sql-antipatterns/)

### raw.githubusercontent.com

- [queue schema](https://raw.githubusercontent.com/rails/solid_queue/main/lib/generators/solid_queue/install/templates/db/queue_schema.rb)

### red-gate.com

- [Look-up Tables in SQL](https://www.red-gate.com/simple-talk/databases/sql-server/t-sql-programming-sql-server/look-up-tables-in-sql/)

### rfc-editor.org

- [RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html)

### riverqueue.com

- [River docs](https://riverqueue.com/docs)

### shop.elsevier.com

- [Trees and Hierarchies in SQL for Smarties, 2nd ed.](https://shop.elsevier.com/books/joe-celkos-trees-and-hierarchies-in-sql-for-smarties/celko/978-0-12-387733-8)

### sigmodrecord.org

- [Temporal features in SQL:2011](https://sigmodrecord.org/2012/09/30/temporal-features-in-sql2011/)

### slideshare.net

- [Models for Hierarchical Data](https://www.slideshare.net/billkarwin/models-for-hierarchical-data)
- [Practical Object-Oriented Models in SQL](https://www.slideshare.net/billkarwin/practical-object-oriented-models-in-sql)
- [author-uploaded copy](https://www.slideshare.net/slideshow/datamodelingpaper/49659552)

### sqlite.org

- [JSON functions](https://www.sqlite.org/json1.html)
- [CREATE TABLE: ROWIDs and the INTEGER PRIMARY KEY](https://www.sqlite.org/lang_createtable.html)
- [WITHOUT ROWID](https://www.sqlite.org/withoutrowid.html)

### sqlservercentral.com

- [Lookup Table Madness](https://www.sqlservercentral.com/articles/lookup-table-madness)
