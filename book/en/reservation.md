---
group: reliable-writes
status: draft
related: [effective-dating, version-column, queue-table]
---

# Reservation

A reservation is a temporary claim on limited capacity — a hotel room for given nights, a seat on a flight, an item in a cart — that expires unless confirmed. The schema must guarantee that claims never exceed capacity even under concurrent requests: with exclusion constraints on time ranges for slots, and with counters and row locks for quantities. The chapter covers holds with expiry, confirmation and cancellation, cleaning up expired holds, and how the structure differs for time slots and for stock.
