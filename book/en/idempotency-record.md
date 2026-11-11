---
group: reliable-writes
status: draft
related: [transactional-outbox, queue-table, double-entry-ledger]
---

# Idempotency Record

An idempotency record makes a retried operation safe: the client sends a unique key with the request, and the server stores the key and the result in the same transaction as the effect. A repeated request with the same key returns the stored result instead of charging the card twice. The chapter shows the table, the unique constraint that settles races between concurrent retries, how long to keep keys, how to detect a key reused for a different request, and the consumer-side variant that records processed message IDs.
