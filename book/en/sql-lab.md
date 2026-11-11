---
group: appendices
status: draft
related: []
---

# SQL Lab

SQL Lab explains how to run the book's examples. Each chapter's full scripts live next to the book together with the PostgreSQL version they were checked on, so you can create the schema, run the operations and see the constraint errors for yourself. The appendix covers starting a local PostgreSQL instance and how the scripts are organized.

## What you need

The 52 pattern and anti-pattern chapters each have one script at `book/assets/<slug>/<slug>.sql`. Their headers record PostgreSQL 18.6 as the checked version. Use a PostgreSQL 18 server and its `psql` client: examples include `uuidv7()`, temporal keys, PostgreSQL ranges, PL/pgSQL and `psql` backslash commands. Other engines' implementation notes in the chapters are porting guidance, not claims that these files run unchanged there.

Use a disposable cluster with a superuser connection. Some examples create roles, change privileges and install the supplied `ltree` or `btree_gist` extensions. The tenant examples also create passwordless login roles, and Database per Tenant creates `dt_a` and `dt_b` and reconnects as its runtime roles. Those reconnects require the lab's local trust authentication. A fresh database alone does not isolate cluster-wide roles or those extra databases.

The commands below start from the repository root. Choose either server setup, then run one example or the complete suite. Keep server messages in English: several scripts compare the exact diagnostic as well as its SQLSTATE. Leave `plpgsql.check_asserts` enabled so the scripts' `ASSERT` checks execute.

## A PostgreSQL 18 Docker container

The [official PostgreSQL image](https://hub.docker.com/_/postgres) provides the server and clients. This lab uses no published port, disables container networking and stores the cluster in temporary memory; local trust lets the tenant scripts reconnect without passwords. PostgreSQL 18 images use `/var/lib/postgresql` as the volume location.

```sh
docker run --detach --name ddp-sql-lab \
  --network none \
  --tmpfs /var/lib/postgresql \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --mount "type=bind,source=$PWD,target=/book,readonly" \
  postgres:18

until docker exec ddp-sql-lab pg_isready -q -h 127.0.0.1 -U postgres; do
  sleep 1
done
docker exec ddp-sql-lab psql -X -U postgres -d postgres \
  -c 'SELECT version();'
```

If readiness never arrives, inspect `docker logs ddp-sql-lab`. The repository is mounted read-only at `/book`; its SQL scripts remain ordinary files, not initialization hooks. For example, run Surrogate Key in its own fresh database:

```sh
docker exec ddp-sql-lab createdb -U postgres --template=template0 lab_one
docker exec ddp-sql-lab psql -X -v ON_ERROR_STOP=1 -U postgres \
  -d lab_one -f /book/book/assets/surrogate-key/surrogate-key.sql
docker exec ddp-sql-lab dropdb -U postgres lab_one
```

When you finish all experiments, remove the container and its temporary cluster:

```sh
docker rm --force --volumes ddp-sql-lab
```

## A local throwaway cluster

Install the full PostgreSQL 18 server distribution, including `initdb`, `pg_ctl`, `postgres`, clients and supplied extensions. A client-only installation cannot create this cluster. Put that distribution's `bin` directory first on `PATH`; for Homebrew on Apple Silicon the path is shown below. On another installation, replace it with your PostgreSQL 18 binary directory.

```sh
export PATH=/opt/homebrew/opt/postgresql@18/bin:$PATH
postgres --version
psql --version

lab_dir=$(mktemp -d /tmp/ddp.XXXXXX)
initdb -D "$lab_dir/data" -U postgres --locale=C --encoding=UTF8 \
  --auth-local=trust --auth-host=reject
pg_ctl -D "$lab_dir/data" -l "$lab_dir/server.log" \
  -o "-k $lab_dir -c listen_addresses=''" -w start

export PGHOST="$lab_dir" PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
psql -X -c 'SELECT version();'
```

Run this as your ordinary operating-system user, not root. [`initdb`](https://www.postgresql.org/docs/18/app-initdb.html) creates the cluster and the named database superuser; [`pg_ctl`](https://www.postgresql.org/docs/18/app-pg-ctl.html) starts it and waits for readiness. The short `/tmp` path keeps the Unix socket pathname short. An empty `listen_addresses` disables TCP; `PGHOST` selects the socket directory, so this does not use an existing server listening on TCP port 5432.

Keep the shell and `lab_dir` value until cleanup. After running the examples, stop the server before deleting its directory:

```sh
pg_ctl -D "$lab_dir/data" -m fast -w stop
rm -rf -- "$lab_dir"
unset PGHOST PGPORT PGUSER PGDATABASE
```

## Run one script

With the local cluster running and the connection variables exported, create a database from `template0`, run one file, and drop the database:

```sh
createdb --maintenance-db=postgres --template=template0 lab_one
psql -X -v ON_ERROR_STOP=1 --dbname=lab_one \
  --file=book/assets/surrogate-key/surrogate-key.sql
dropdb --maintenance-db=postgres lab_one
```

[`psql -X`](https://www.postgresql.org/docs/18/app-psql.html) ignores startup files, and `ON_ERROR_STOP=1` makes unexpected errors stop the file with a nonzero exit status. Keep that option even though most scripts also set it themselves. Do not add `--single-transaction`: scripts own their transaction boundaries, some deliberately commit, and Database per Tenant issues `CREATE DATABASE` and reconnects.

Many examples roll their lab transaction back at the end. Others leave schemas and rows for inspection, so use a new database for each attempt rather than assuming a file is rerunnable. The tenant labs leave cluster-wide objects too; use the complete runner below for their cleanup or discard the entire cluster after running them manually. Sequential example statements demonstrate protocols and assertions; a passing file does not itself exercise every two-session race shown in a chapter.

## Recognize intended failures

An `ERROR` line is sometimes the demonstration succeeding. Judge it by the nearby expectation check and the final process status, not by searching the output for the word `ERROR`.

| Convention in the scripts | What happens | What makes a run fail |
| --- | --- | --- |
| Savepoint plus temporarily disabled `ON_ERROR_STOP` | An invalid statement prints an error; the script saves `:SQLSTATE`, enables stopping again and rolls back to the savepoint | Saved state differs from the expected one, including when the invalid statement unexpectedly succeeds |
| `DO` block with a named exception handler | An inner block attempts the invalid operation, catches only the expected condition and prints a notice | An unexpected exception escapes, a checked diagnostic differs, or the explicit failure after unexpected success escapes |
| `pg_temp.expect_error` helper in the anti-pattern labs | Dynamic SQL runs inside an exception block; stacked diagnostics capture state and message | Either state or exact message differs; no exception also fails the comparison |
| Assertions and result gates | `ASSERT`, explicit `IF ... RAISE EXCEPTION`, or a query followed by `\gset` and `\if` checks resulting data | A failed gate raises an exception, deliberately evaluates `1 / 0`, or issues `\quit 1` |

For example, [Surrogate Key's script](../assets/surrogate-key/surrogate-key.sql) uses this sequence inside its lab transaction:

```sql
SAVEPOINT expected_error;
\set ON_ERROR_STOP off
INSERT INTO customer (customer_number, display_name)
VALUES ('C-204', 'Duplicate');
\set rejected_state :SQLSTATE
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT expected_error;
SELECT :'rejected_state' = '23505' AS rejected \gset
\if :rejected
\else
    \quit 1
\endif
```

The saved state must be `23505` (unique violation). It is captured before `ROLLBACK TO`, because subsequent SQL changes `:SQLSTATE`. `expected_error` is a savepoint name used by several scripts, not a special PostgreSQL feature; other files use descriptive names such as `rejected_operation`. The rollback recovers the transaction so later assertions can run.

[Exclusive Arc](../assets/exclusive-arc/exclusive-arc.sql) instead catches `check_violation` or `foreign_key_violation` in `DO` blocks and prints the expected SQLSTATE. Its deliberate `RAISE EXCEPTION` after an operation ensures that unexpected success is not silently accepted. Some handlers also compare `SQLERRM`. [Delimited Lists](../assets/delimited-lists/delimited-lists.sql) defines the reusable temporary helper, while [Association Table](../assets/association-table/association-table.sql) includes `ASSERT` checks of retained rows and cascade effects.

Successful checks can therefore produce raw errors, notices and ordinary query output in the same run. A nonzero `psql` status is a broken lab run even if earlier expected-error notices appeared. An unchanged script failing on a different diagnostic language or server version still needs investigation; do not suppress its assertions to obtain a pass.

## Run all scripts

The [POSIX shell runner](../assets/sql-lab/run-all.sh) uses `set -eu` and PostgreSQL clients from `PATH`. It takes host/socket, port, user and other connection defaults from the standard [PG environment variables](https://www.postgresql.org/docs/18/libpq-envars.html). `PGDATABASE` names the maintenance database, defaulting to `postgres`; each script gets an explicitly selected fresh database. The Database per Tenant example also reconnects to `postgres`, so keep that database available.

For the local cluster:

```sh
sh book/assets/sql-lab/run-all.sh
```

For the Docker setup, run the same file inside the container using its installed clients and local socket:

```sh
docker exec \
  --env PGHOST=/var/run/postgresql --env PGUSER=postgres \
  --env PGDATABASE=postgres \
  ddp-sql-lab sh /book/book/assets/sql-lab/run-all.sh
```

The runner discovers `book/assets/*/*.sql` in pathname order, independently of your working directory. For each file it creates a uniquely named database from `template0`, runs `psql -X -v ON_ERROR_STOP=1`, drops the database and prints `PASS <slug>`. It stops at the first nonzero script exit and prints `FAIL <slug>`; its exit trap attempts cleanup on failure or interruption. Cleanup failures also fail the run. With all current files passing, the final line is `PASS: 52 scripts`.

The runner also removes the tenant labs' auxiliary databases (`dt_a`, `dt_b`) and roles (`ss_app`, `st_owner`, `st_app_a`, `st_app_b`, `dt_owner`, `dt_app_a`, `dt_app_b`). Audit Log creates `audit_example_app` inside a transaction that rolls back. A preflight check rejects any of these existing names before running anything; it does not reuse or delete pre-existing lab objects. Run only one suite at a time in its disposable cluster. After an uncatchable termination or a cleanup failure, discard that cluster and start another.

The complete suite has been run successfully on a throwaway PostgreSQL 18.6 cluster: all 52 files passed with these checks enabled. The outbox lab assumes a broker acknowledgement in SQL rather than contacting a broker; queue and reservation examples advance test state instead of waiting for real worker deadlines.

## Script catalog

The groups and chapter order below follow the book's [Summary](SUMMARY.md). Each file is self-contained for its documented lab setup; the preceding chapter is not a prerequisite.

### Identity

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Surrogate Key](surrogate-key.md) | [surrogate-key.sql](../assets/surrogate-key/surrogate-key.sql) | Stable internal references through a business-number change; business uniqueness and UUID alternatives. |
| [Natural Key](natural-key.md) | [natural-key.sql](../assets/natural-key/natural-key.sql) | Composite line identity and cascading correction through dependent references. |
| [Time-Ordered Identifier](time-ordered-identifier.md) | [time-ordered-identifier.sql](../assets/time-ordered-identifier/time-ordered-identifier.sql) | UUIDv7 generation, extraction, explicit insertion and duplicate rejection. |
| [Public Identifier](public-identifier.md) | [public-identifier.sql](../assets/public-identifier/public-identifier.sql) | Resolve and rotate an external handle while retaining internal references. |

### Relationships

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Association Table](association-table.md) | [association-table.sql](../assets/association-table/association-table.sql) | Membership attributes, pair uniqueness, endpoint FKs and cascade effects. |
| [Table Split](table-split.md) | [table-split.sql](../assets/table-split/table-split.sql) | Optional shared-key details and the deferred mandatory-extension variant. |
| [Ordered Collection](ordered-collection.md) | [ordered-collection.sql](../assets/ordered-collection/ordered-collection.sql) | Gapped positions, renumbering, swaps and owner-scoped uniqueness. |
| [Localized Values](localized-values.md) | [localized-values.sql](../assets/localized-values/localized-values.sql) | Translation rows, required default, atomic default switch and language-specific search. |

### Reference and State

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Lookup Table](lookup-table.md) | [lookup-table.sql](../assets/lookup-table/lookup-table.sql) | Maintained status labels and retirement guards, with separate enum/domain alternatives. |
| [Status History](status-history.md) | [status-history.sql](../assets/status-history/status-history.sql) | Guarded transitions, revision rejection and atomic current/history writes. |

### Hierarchies

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Adjacency List](adjacency-list.md) | [adjacency-list.sql](../assets/adjacency-list/adjacency-list.sql) | Recursive descendants and breadcrumbs, guarded move and subtree deletion. |
| [Materialized Path](materialized-path.md) | [materialized-path.sql](../assets/materialized-path/materialized-path.sql) | `ltree` containment and transactional branch-path rewrites with parent consistency. |
| [Nested Sets](nested-sets.md) | [nested-sets.sql](../assets/nested-sets/nested-sets.sql) | Insert, move and delete dense intervals, then audit density and crossings. |
| [Closure Table](closure-table.md) | [closure-table.sql](../assets/closure-table/closure-table.sql) | Maintain ancestor pairs through a move/delete and compare closure with direct edges. |

### Types and Attributes

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Single Table Inheritance](single-table-inheritance.md) | [single-table-inheritance.sql](../assets/single-table-inheritance/single-table-inheritance.sql) | Discriminator-based row-shape checks and family-wide references. |
| [Class Table Inheritance](class-table-inheritance.md) | [class-table-inheritance.sql](../assets/class-table-inheritance/class-table-inheritance.sql) | Deferred subtype completeness, wrong-type rejection and atomic conversion. |
| [Concrete Table Inheritance](concrete-table-inheritance.md) | [concrete-table-inheritance.sql](../assets/concrete-table-inheritance/concrete-table-inheritance.sql) | Separate complete types, shared allocation, union reads and subtype-specific FKs. |
| [Exclusive Arc](exclusive-arc.md) | [exclusive-arc.sql](../assets/exclusive-arc/exclusive-arc.sql) | Exactly-one real target, ownership transfer and target deletion behavior. |
| [JSON Column](json-column.md) | [json-column.sql](../assets/json-column/json-column.sql) | Validate/index document paths and use a version for whole-document editing. |
| [Typed Properties](typed-properties.md) | [typed-properties.sql](../assets/typed-properties/typed-properties.sql) | Publish property profiles, validate typed values/completeness and migrate a product's profile. |

### Time and Deletion

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [History Table](history-table.md) | [history-table.sql](../assets/history-table/history-table.sql) | Capture row versions, query past values, prevent identity reuse and apply retention. |
| [Effective Dating](effective-dating.md) | [effective-dating.sql](../assets/effective-dating/effective-dating.sql) | Nonoverlapping business periods, as-of selection and temporal coverage references. |
| [Bitemporal Table](bitemporal-table.md) | [bitemporal-table.sql](../assets/bitemporal-table/bitemporal-table.sql) | Correct business history while retaining earlier recorded beliefs and overlap protection. |
| [Audit Log](audit-log.md) | [audit-log.sql](../assets/audit-log/audit-log.sql) | Attributed atomic actions and runtime permissions that reject evidence rewriting. |
| [Soft Delete](soft-delete.md) | [soft-delete.sql](../assets/soft-delete/soft-delete.sql) | Live-only uniqueness, retained references, restore conflict and physical-delete protection. |

### Domain Structures

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Party](party.md) | [party.sql](../assets/party/party.sql) | Common counterparty identity, typed extensions and registration uniqueness. |
| [Role Object](role-object.md) | [role-object.sql](../assets/role-object/role-object.sql) | Dated participation episodes, typed role references and conflicting-period rejection. |
| [Quantity](quantity.md) | [quantity.sql](../assets/quantity/quantity.sql) | Compatible multiplicative conversions, dimension checks and refused currency conversion. |
| [Observation](observation.md) | [observation.sql](../assets/observation/observation.sql) | Immutable typed evidence, replacements, rejection and derived observation status. |
| [Bill of Materials](bill-of-materials.md) | [bill-of-materials.sql](../assets/bill-of-materials/bill-of-materials.sql) | Release/pin recipe versions, explode path quantities and select releases by business date. |
| [Double-Entry Ledger](double-entry-ledger.md) | [double-entry-ledger.sql](../assets/double-entry-ledger/double-entry-ledger.sql) | Balanced atomic posting, immutable entries, currency checks and exact reversal. |

### Reliable Writes

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Version Column](version-column.md) | [version-column.sql](../assets/version-column/version-column.sql) | Conditional updates reject stale snapshots and advance an aggregate token. |
| [Reservation](reservation.md) | [reservation.sql](../assets/reservation/reservation.sql) | Slot overlap protection and pooled-stock hold, confirmation, cancellation and expiry. |
| [Idempotency Record](idempotency-record.md) | [idempotency-record.sql](../assets/idempotency-record/idempotency-record.sql) | Saved-result replay, changed-payload rejection and consumer effect deduplication. |
| [Transactional Outbox](transactional-outbox.md) | [transactional-outbox.sql](../assets/transactional-outbox/transactional-outbox.sql) | Atomic producer staging, ordered relay acknowledgement and rollback of failed production. |
| [Queue Table](queue-table.md) | [queue-table.sql](../assets/queue-table/queue-table.sql) | Claims, lease generations, stale acknowledgements, renewal, recovery and terminal attempts. |

### Tenant Isolation

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Shared Schema](shared-schema.md) | [shared-schema.sql](../assets/shared-schema/shared-schema.sql) | Tenant-scoped FKs, restricted-role RLS and transaction-local context reset. |
| [Schema per Tenant](schema-per-tenant.md) | [schema-per-tenant.sql](../assets/schema-per-tenant/schema-per-tenant.sql) | Separate grants, transaction-local routing and per-schema migration markers. |
| [Database per Tenant](database-per-tenant.md) | [database-per-tenant.sql](../assets/database-per-tenant/database-per-tenant.sql) | Provision two databases and credentials, validate destination identity and reject cross-database access. |

### Growth and Change

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Summary Table](summary-table.md) | [summary-table.sql](../assets/summary-table/summary-table.sql) | Maintain deltas, reconcile drift, rebuild totals and refresh a materialized view. |
| [Table Partitioning](table-partitioning.md) | [table-partitioning.sql](../assets/table-partitioning/table-partitioning.sql) | Route ranges, enforce composite keys, handle missing partitions and detach/reattach data. |
| [Expand and Contract](expand-contract.md) | [expand-contract.sql](../assets/expand-contract/expand-contract.sql) | Bridge old/new contracts through rename, table split and type-conversion rollouts. |

### Anti-patterns

| Chapter | Script | Demonstration |
| --- | --- | --- |
| [Delimited Lists](delimited-lists.md) | [delimited-lists.sql](../assets/delimited-lists/delimited-lists.sql) | Expose substring mistakes, parse imported members and quarantine unknown IDs. |
| [Mandatory Surrogates](mandatory-surrogates.md) | [mandatory-surrogates.sql](../assets/mandatory-surrogates/mandatory-surrogates.sql) | Repair pair identity while retaining an old-ID map and showing the unique-pair alternative. |
| [Missing Foreign Keys](missing-foreign-keys.md) | [missing-foreign-keys.sql](../assets/missing-foreign-keys/missing-foreign-keys.sql) | Quarantine orphans, enforce new references and validate existing rows. |
| [Repeated Columns](repeated-columns.md) | [repeated-columns.sql](../assets/repeated-columns/repeated-columns.sql) | Unpivot numbered slots into constrained membership rows. |
| [Polymorphic Associations](polymorphic-associations.md) | [polymorphic-associations.sql](../assets/polymorphic-associations/polymorphic-associations.sql) | Replace unchecked kind/ID values with a validated exclusive arc. |
| [Untyped Properties](untyped-properties.md) | [untyped-properties.sql](../assets/untyped-properties/untyped-properties.sql) | Audit conversions, quarantine invalid properties and populate typed constrained columns. |
| [Volatile Enums](volatile-enums.md) | [volatile-enums.sql](../assets/volatile-enums/volatile-enums.sql) | Migrate a schema vocabulary to maintained lookup rows with retained references. |
| [Fixed-Depth Queries](fixed-depth-queries.md) | [fixed-depth-queries.sql](../assets/fixed-depth-queries/fixed-depth-queries.sql) | Compare truncated joins with recursive traversal and retain parent integrity. |
| [Cloned Tables](cloned-tables.md) | [cloned-tables.sql](../assets/cloned-tables/cloned-tables.sql) | Consolidate dated tables with a reviewed identity map and one constrained relation. |
| [Inexact Arithmetic](inexact-arithmetic.md) | [inexact-arithmetic.sql](../assets/inexact-arithmetic/inexact-arithmetic.sql) | Review approximate amounts, migrate to exact decimals and reject invalid scale/nonfinite values. |
