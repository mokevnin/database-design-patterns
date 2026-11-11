---
kind: anti-pattern
status: draft
related: [adjacency-list, closure-table]
---

# Fixed-Depth Queries

Fixed-depth queries read a tree stored as an adjacency list with a fixed number of self-joins, one per level, on the assumption that the hierarchy will never go deeper than three or four levels. The query silently drops nodes below the last join, and every new level means rewriting it. The chapter shows how recursive CTEs remove the limit and when another tree structure fits better; the adjacency list itself is not the problem. Bill Karwin calls this Naive Trees.
