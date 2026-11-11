---
kind: anti-pattern
status: draft
related: [polymorphic-associations, expand-contract]
---

# Missing Foreign Keys

Missing foreign keys means storing references without declaring them as foreign key constraints, usually to save on performance or to keep integrity in the application. Sooner or later rows appear that point to deleted or never-existing records, and every query and report has to defend against them. The chapter shows how orphans appear, what declaring the constraint really costs, and how to clean up existing data and add constraints without long locks. Bill Karwin calls this Keyless Entry.
