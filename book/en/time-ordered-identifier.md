---
group: identity
status: draft
related: [surrogate-key, public-identifier]
---

# Time-Ordered Identifier

A time-ordered identifier is a globally unique ID whose leading bits encode the creation time: UUIDv7 from RFC 9562, ULID, or a Snowflake-style 64-bit value. New rows land at the right edge of a B-tree index the way sequential integers do, while IDs can still be generated in the application or on many nodes without coordination. The chapter compares the formats, explains what ordering they do and do not guarantee within one millisecond and across machines, and what the embedded timestamp reveals to anyone who sees the ID.
