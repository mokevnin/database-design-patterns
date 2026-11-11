---
group: reliable-writes
status: draft
related: [reservation, status-history, ordered-collection]
---

# Version Column

A version column implements optimistic locking: each row carries a counter or timestamp, and an update succeeds only if the version is still the one the client read. Two people editing the same record no longer overwrite each other silently — the second gets a conflict and can reload. The chapter shows the update statement and how to detect zero affected rows, how ORMs implement it, native row versions such as `rowversion` in SQL Server and `xmin` in PostgreSQL, and when pessimistic locking is the better choice.
