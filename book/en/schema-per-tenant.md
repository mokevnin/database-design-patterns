---
group: tenant-isolation
status: draft
related: [shared-schema, database-per-tenant]
---

# Schema per Tenant

Schema per tenant gives each tenant its own schema with an identical set of tables inside one database. Isolation is stronger than in a shared schema, a tenant can be backed up, restored or moved separately, and per-tenant customization becomes possible. The chapter shows how to route connections to the right schema, why migrations now run once per tenant, and how the number of schemas affects catalog size, connection pools and tooling.
