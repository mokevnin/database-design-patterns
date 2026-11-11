---
kind: anti-pattern
status: draft
related: [exclusive-arc, class-table-inheritance, missing-foreign-keys]
---

# Polymorphic Associations

Polymorphic associations reference a row in one of several tables through a pair of columns — the target type and the target ID — as Rails polymorphic associations and Django generic relations do. No foreign key can check such a reference, so the database lets a comment point to a post that never existed, and every join needs a CASE on the type. The chapter shows the harm and three ways out: an exclusive arc, a separate association table per target, and a shared supertype. Bill Karwin's catalog uses the same name.
