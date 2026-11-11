---
group: time-and-deletion
status: draft
related: [history-table, status-history, bitemporal-table]
---

# Audit Log

An audit log is an append-only record of actions: who changed what, when, from where and why, often for many tables in one place. Unlike a history table, its purpose is not to rebuild past states but to account for each change, so it records the actor, the reason, and a correlation ID that ties the change to a request. The chapter covers what the database can capture and what only the application knows, how permissions make the log append-only, and what tamper evidence such as hash chains or ledger tables adds, and against which threat.
