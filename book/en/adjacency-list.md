---
group: hierarchies
status: draft
related: [materialized-path, nested-sets, closure-table, fixed-depth-queries]
---

# Adjacency List

An adjacency list stores a tree by giving each row a reference to its parent in the same table. It is the simplest structure to write and keep consistent: moving a subtree changes one value, and a foreign key guarantees that every parent exists. The chapter shows how recursive common table expressions read descendants, ancestors and paths in one query, how to prevent cycles, and at what depth and read volume the alternatives start to pay off.
