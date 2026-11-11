---
group: identity
status: draft
related: [natural-key, time-ordered-identifier, public-identifier, mandatory-surrogates]
---

# Surrogate Key

A surrogate key is a value the database generates solely to identify a row: it carries no business meaning, never changes, and is what every foreign key points to. The chapter covers the real decision behind it — a bigint identity column, a random UUIDv4 or a time-ordered UUIDv7/ULID — and what each choice costs in index size, insert locality, merging data from several databases, and generating IDs before the row reaches the database. It also shows why a surrogate key does not replace a uniqueness constraint on the business attributes: without one, the same customer quietly appears twice.
