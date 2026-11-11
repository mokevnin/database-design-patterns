---
kind: anti-pattern
status: draft
related: [quantity, double-entry-ledger]
---

# Inexact Arithmetic

Inexact arithmetic stores money and other exact quantities in floating-point columns, whose binary representation cannot hold most decimal fractions exactly. Sums drift by fractions of a cent, equality comparisons fail, and reports disagree with the bank. The chapter shows the errors, the `numeric`/`decimal` types and integer minor units as the fix, and where rounding rules have to be explicit. Bill Karwin calls this Rounding Errors.
