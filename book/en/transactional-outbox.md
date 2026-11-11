---
group: reliable-writes
status: draft
related: [idempotency-record, queue-table]
---

# Transactional Outbox

A transactional outbox solves the dual-write problem: when a service changes data and must publish an event, it writes the event to an outbox table in the same transaction as the change. A separate relay — a polling process or change data capture such as Debezium — reads the outbox and delivers events to a message broker. The chapter shows the outbox table, ordering and delivery guarantees, why consumers must tolerate duplicates, and how to clean up delivered rows.
