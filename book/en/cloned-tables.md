---
kind: anti-pattern
status: draft
related: [table-partitioning, shared-schema]
---

# Cloned Tables

Cloned tables split one kind of data across many identical tables — `orders_2024`, `orders_2025`, or one table per customer — to keep each of them small. Queries across them need UNION and dynamic SQL, constraints cannot span them, and every schema change has to be repeated in all of them. The chapter shows how table partitioning, or an ordinary column with an index, solves the same problem. Bill Karwin calls this Metadata Tribbles.
