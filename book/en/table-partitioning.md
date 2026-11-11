---
group: growth-and-change
status: draft
related: [summary-table, cloned-tables, expand-contract]
---

# Table Partitioning

Table partitioning splits one large table into partitions by range, list or hash of a key, while queries still see a single table. Old data can be detached or dropped a whole partition at a time instead of with a long DELETE, and queries that filter by the partition key read only the partitions they need. The chapter shows declarative partitioning in PostgreSQL, choosing the key, the restrictions it places on primary keys and unique constraints, and the overhead as the number of partitions grows.
