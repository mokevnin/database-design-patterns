---
group: domain-structures
status: draft
related: [quantity, summary-table, idempotency-record, inexact-arithmetic]
---

# Double-Entry Ledger

A double-entry ledger records every movement of money as a transaction of entries between accounts, in which debits and credits sum to zero. The schema guarantees that money is never created or lost, only moved, and that every balance can be derived from the entries. The chapter shows accounts, transactions and entries, how to enforce the balancing rule, immutable entries corrected by reversals instead of updates, and when to store running balances for speed. The same structure tracks stock moving between warehouses.
