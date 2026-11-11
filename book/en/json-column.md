---
group: types-and-attributes
status: draft
related: [typed-properties, single-table-inheritance, untyped-properties]
---

# JSON Column

A JSON column stores semi-structured attributes — device settings, product specifications that differ by category, payloads from external systems — in a single JSONB value next to the regular columns. You get a flexible shape without migrations and can still query it with operators, GIN indexes, and generated columns that pull frequently used fields into ordinary typed columns. The chapter shows where to draw the line between JSON and columns, how CHECK constraints and schema validation win back some guarantees, and what you lose in foreign keys, statistics and type safety.
