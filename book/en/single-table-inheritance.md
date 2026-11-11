---
group: types-and-attributes
status: draft
related: [class-table-inheritance, concrete-table-inheritance, json-column]
---

# Single Table Inheritance

Single table inheritance stores all subtypes of an entity — say, individual and corporate customers — in one table with a column that names the type and the union of all subtype columns. Queries across subtypes need no joins, and adding a subtype rarely needs a new table. The chapter shows how CHECK constraints keep subtype-specific columns filled or empty according to the type, a rule otherwise left to the application, and when a growing number of nullable columns signals that another inheritance mapping fits better.
