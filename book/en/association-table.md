---
group: relationships
status: draft
related: [natural-key, delimited-lists, repeated-columns]
---

# Association Table

An association table turns a many-to-many relationship into rows: each row links one record on each side through two foreign keys, and the pair is the key. As soon as the link has facts of its own — the quantity on an order line, a member's role in a project, the date a tag was added — they become columns of the association table, and it grows into an entity in its own right. The chapter covers choosing between a composite primary key and a surrogate, the indexes each direction of navigation needs, and keeping links unique.
