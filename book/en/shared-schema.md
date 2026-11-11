---
group: tenant-isolation
status: draft
related: [schema-per-tenant, database-per-tenant, cloned-tables]
---

# Shared Schema

A shared schema keeps the data of all tenants in the same tables, told apart by a `tenant_id` column on every row. It is the cheapest model to operate — one schema to migrate, one connection pool — but isolation is only as good as the filter in every query. The chapter shows how to make `tenant_id` part of keys and foreign keys so that rows of different tenants cannot reference each other, how PostgreSQL row-level security enforces the filter in the database, and what to do with a tenant that outgrows the rest.
