---
group: relationships
status: draft
related: [class-table-inheritance, json-column]
---

# Table Split

A table split moves part of an entity's columns into a second table that shares its primary key, forming a one-to-one relationship. You do it for different reasons: optional data that only some rows have, large or rarely read columns that bloat the main table, or columns with different access rules or change rates. The chapter separates these motivations, shows how keys and constraints enforce "at most one" and, where needed, "exactly one", and when the extra join costs more than it saves.
