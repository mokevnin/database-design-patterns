---
group: types-and-attributes
status: draft
related: [class-table-inheritance, polymorphic-associations]
---

# Exclusive Arc

An exclusive arc lets a row refer to exactly one of several possible parent tables — a comment on either a post or a photo — by giving it one nullable foreign key per target and a CHECK constraint that exactly one of them is set. Every reference is a real foreign key, so the database guarantees the target exists and cascades work as usual. The chapter shows the constraint and the index each key needs, and when the number of possible targets makes a shared supertype or per-target association tables the better choice.
