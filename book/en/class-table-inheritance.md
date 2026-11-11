---
group: types-and-attributes
status: draft
related: [single-table-inheritance, concrete-table-inheritance, exclusive-arc, party, polymorphic-associations]
---

# Class Table Inheritance

Class table inheritance gives the shared attributes of a family of types one supertype table and each subtype its own table, whose primary key is also a foreign key to the supertype. Every column lives in exactly one place, can be NOT NULL where the subtype demands it, and other tables can reference either the supertype or one specific subtype. The chapter covers guaranteeing that each supertype row has exactly one matching subtype row, the cost of joins when reading a whole object, and how the same structure works as a shared supertype for references that may point to several kinds of entity.
