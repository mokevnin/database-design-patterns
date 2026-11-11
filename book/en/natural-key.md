---
group: identity
status: draft
related: [surrogate-key, association-table, mandatory-surrogates]
---

# Natural Key

A natural key identifies a row by attributes the business already uses — an ISO country code, an ISBN, an order number together with a line number. Making it the primary key removes lookup joins and rules out duplicates by construction, but every change to the business value ripples through all referencing rows. The chapter shows how to judge whether a value is stable, unique and always known at insert time, how composite keys work and when they pay off, and how to keep a natural key as a unique constraint even when a surrogate is the primary key.
