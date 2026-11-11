---
group: hierarchies
status: draft
related: [adjacency-list, nested-sets, closure-table]
---

# Materialized Path

A materialized path stores in each row the full path from the root to the node, such as `1.4.17`. Subtree and ancestor queries become prefix comparisons that an ordinary index can serve, and PostgreSQL's `ltree` and SQL Server's `hierarchyid` offer native types and operators for it. The chapter covers path encoding, ordering siblings, the cost of moving a subtree, which rewrites the path of every descendant, and why only triggers or application code keep the path consistent with the parent reference.
