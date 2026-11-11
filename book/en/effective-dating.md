---
group: time-and-deletion
status: draft
related: [history-table, bitemporal-table, reservation]
---

# Effective Dating

Effective dating gives each row the business period during which it is valid: a price from the first of the month, an employee's position until a given date, a contract version for one year. The key is the entity plus its period, and the database enforces that periods of the same entity do not overlap — with an exclusion constraint on a range type, `WITHOUT OVERLAPS` in PostgreSQL 18, or SQL:2011 application-time periods in other engines. The chapter covers half-open intervals, finding the value valid at a date, and changing a period without leaving gaps.
