---
group: hierarchies
status: draft
related: [adjacency-list, materialized-path, closure-table]
---

# Nested Sets

Nested sets number the nodes of a tree with left and right bounds from a depth-first walk, so every descendant's bounds lie inside its ancestor's. Reading a whole subtree, counting descendants and ordering a tree for display become single range queries without recursion. The price is paid on writes: inserting or moving a node renumbers a large part of the table under a lock. The chapter shows when a hierarchy that is read often and changed rarely, such as a product catalog, justifies that trade.
