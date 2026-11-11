---
group: reference-and-state
status: draft
related: [status-history, volatile-enums]
---

# Lookup Table

A lookup table restricts a column to a fixed vocabulary — order statuses, countries, payment methods — by keeping the allowed values in their own table and referencing them with a foreign key. It competes with a native enum type, a CHECK constraint and a domain, and the chapter treats the choice as one decision: how often the list changes, whether values carry their own attributes such as labels or sort order, and what a change costs as a migration. It also shows the failure mode of folding every vocabulary into one generic table, known as One True Lookup Table.
