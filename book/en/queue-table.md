---
group: reliable-writes
status: draft
related: [transactional-outbox, idempotency-record, reservation]
---

# Queue Table

A queue table keeps background jobs in an ordinary table, and workers claim them with `SELECT ... FOR UPDATE SKIP LOCKED`, so each job goes to exactly one worker without blocking the others. A queue in the same database as the data lets you enqueue a job in the same transaction as the change that requires it. The chapter covers job states, retries with backoff, timeouts for crashed workers, priorities, cleanup of finished jobs, and the load at which a dedicated broker becomes the better tool.
