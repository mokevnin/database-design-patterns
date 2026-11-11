---
group: hierarchies
status: draft
related: [adjacency-list, materialized-path, nested-sets, bill-of-materials]
---

# Closure Table

A closure table stores every ancestor–descendant pair of a tree in a separate table, usually with the distance between them. Descendant, ancestor and depth-limited queries become plain joins on an indexed table without recursion, and foreign keys guarantee that every pair refers to real nodes. The chapter shows how inserts, deletes and subtree moves update the pairs, how much space the table takes as trees grow deep, and how the structure extends to graphs where a node has several parents.
