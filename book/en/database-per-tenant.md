---
group: tenant-isolation
status: draft
related: [shared-schema, schema-per-tenant]
---

# Database per Tenant

Database per tenant gives each tenant a separate database, sometimes on a separate server. It offers the strongest isolation — separate resources, backups, encryption keys, versions, even placement in a required region — which is often a compliance or contract requirement. The chapter covers the operational cost of provisioning, migrating and monitoring many databases, connection routing, reporting across tenants, and mixed models in which large tenants get their own database while small ones share.
