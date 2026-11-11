---
kind: anti-pattern
status: draft
related: [surrogate-key, natural-key, association-table]
---

# Mandatory Surrogates

Mandatory surrogates means adding an `id` column to every table out of habit, even where a natural or composite key is the real identity. In an association table this lets the same pair be linked twice unless a separate unique constraint is added, and elsewhere it hides the business key that should be unique. The chapter shows the duplicates this produces and when a surrogate key is nonetheless the right call. Bill Karwin calls this ID Required.
