---
group: growth-and-change
status: draft
related: [table-partitioning, table-split]
---

# Expand and Contract

Expand and contract changes a schema in a series of backward-compatible steps, so old and new versions of the application work at the same time and no deploy needs downtime. You first expand — add the new column or table — then write to both and backfill, switch reads, and only then contract by removing the old structure. The chapter walks through renaming a column, splitting a table and changing a type this way, and shows how locks taken by DDL statements can still stop production when a step is done carelessly.
