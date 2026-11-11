---
kind: anti-pattern
status: draft
related: [lookup-table]
---

# Volatile Enums

Volatile enums put a list of values that changes with business data — product categories, regions, sales channels — into an enum type or a CHECK constraint. Every new value then needs a schema migration, removing a value is often impossible, and the application cannot list the allowed values without reading the catalog. The chapter shows when such lists belong in a lookup table and when a stable enum is still the better choice. Bill Karwin calls this 31 Flavors.
