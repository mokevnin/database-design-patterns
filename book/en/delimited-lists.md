---
kind: anti-pattern
status: draft
related: [association-table, repeated-columns]
---

# Delimited Lists

Delimited lists store several values in one string column — tag IDs as `'3,7,12'` or e-mail addresses separated by semicolons — to avoid creating another table. Every query then has to parse the string: searching for one value needs pattern matching that indexes cannot serve, joins are impossible, foreign keys cannot check the values, and the column length caps how many fit. The chapter shows how the list breaks, when an array type is an acceptable middle ground, and how to migrate to an association table. Bill Karwin calls this Jaywalking.
