---
group: types-and-attributes
status: draft
related: [single-table-inheritance, class-table-inheritance]
---

# Concrete Table Inheritance

Concrete table inheritance gives each concrete subtype its own complete table that repeats the shared columns, with no table for the supertype. Each table is simple and fast to read on its own, and every column can carry the constraints its subtype needs. The chapter shows what this costs: queries across subtypes need UNION, IDs must stay unique across tables if anything refers to "any subtype", and a change to a shared column must be repeated in every table.
