---
group: types-and-attributes
status: draft
related: [json-column, untyped-properties]
---

# Typed Properties

Typed properties let users or administrators define new attributes without schema changes: a table of property definitions with names, data types and constraints, and a table of values that refers to both the entity and the definition. This is the designed form of entity–attribute–value: values are stored in columns of the right type, required properties and allowed ranges are checked, and definitions can evolve. The chapter shows how to build it, how to query entities by several properties at once, and when a JSON column is the cheaper way to the same goal.
