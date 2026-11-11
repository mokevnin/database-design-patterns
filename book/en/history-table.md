---
group: time-and-deletion
status: draft
related: [effective-dating, bitemporal-table, audit-log, status-history]
---

# History Table

A history table keeps every previous version of a row together with the period during which it was current, so you can ask what a record looked like at any past moment. The chapter shows both ways to maintain it: by hand, with triggers that copy the old row on every update and delete, and with native SQL:2011 system versioning in SQL Server, MariaDB and Db2, where the database maintains the period columns and answers `FOR SYSTEM_TIME AS OF` queries. It covers what history does not record, such as who made the change, and how to keep it from growing without bound.
