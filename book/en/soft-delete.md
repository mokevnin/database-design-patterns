---
group: time-and-deletion
status: draft
related: [history-table, audit-log]
---

# Soft Delete

Soft delete marks a row as deleted, usually with a `deleted_at` timestamp, instead of removing it, so the data can be restored and stays visible to reports. The chapter shows the costs that make it controversial: every query and every unique constraint must account for deleted rows, foreign keys keep pointing at rows the application considers gone, and personal data stays where privacy rules require it to disappear. It compares the approach with moving deleted rows to a separate archive table and shows how partial unique indexes keep uniqueness among live rows.
