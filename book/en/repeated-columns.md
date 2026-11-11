---
kind: anti-pattern
status: draft
related: [association-table, delimited-lists]
---

# Repeated Columns

Repeated columns model several values of one attribute as numbered columns: `tag1`, `tag2`, `tag3`, or `phone_home`, `phone_work`, `phone_mobile`. Searching by value means checking every column, uniqueness among them cannot be declared, and a fourth value needs a migration. The chapter shows the queries that break and the move to a child table, and tells this apart from columns that are genuinely different attributes. Bill Karwin calls this Multicolumn Attributes.
