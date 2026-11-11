---
group: domain-structures
status: draft
related: [observation, inexact-arithmetic, double-entry-ledger]
---

# Quantity

A quantity stores a number together with its unit of measure — kilograms, pieces, hours, euros — instead of a bare number whose unit lives in a column name or in the developer's head. The chapter shows a units table, the unit reference on each amount, conversion factors between units of the same dimension, and constraints that keep kilograms from being added to litres. Money is the special case where the unit is the currency, and the exact decimal type and rounding rules matter as much as the amount.
