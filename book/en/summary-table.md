---
group: growth-and-change
status: draft
related: [double-entry-ledger, table-partitioning]
---

# Summary Table

A summary table stores precomputed aggregates — daily sales totals, comment counts, account balances — so frequent reads no longer scan the source rows. The chapter compares ways to keep it in sync: updates in the same transaction, triggers, periodic refreshes and materialized views, with a counter cache on the parent row as the simplest form. It shows how to keep concurrent increments correct and how to rebuild a summary from the source when it drifts.
