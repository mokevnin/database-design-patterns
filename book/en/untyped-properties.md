---
kind: anti-pattern
status: draft
related: [typed-properties, json-column]
---

# Untyped Properties

Untyped properties store arbitrary attributes as rows of entity, attribute name and a value in a text column — the naive form of entity–attribute–value. The database can no longer check types, require mandatory attributes or enforce references, and every query that needs several attributes turns into a pivot with one join per attribute. The chapter shows these failures and how to migrate to columns, a JSON column or typed properties. Bill Karwin calls this Entity-Attribute-Value.
