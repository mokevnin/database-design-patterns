---
group: time-and-deletion
status: draft
related: [history-table, effective-dating, audit-log]
---

# Bitemporal Table

A bitemporal table records two independent timelines on the same rows: when a fact was true in the business, and when the database knew about it. It answers questions neither history nor effective dating answers alone, such as what the system said on March 1st about the price valid in February — exactly what corrections, audits and recalculated past reports need. The chapter shows the structure and its two periods, how a retroactive correction closes and opens rows, and why the complexity pays off only where past answers must be reproducible.
