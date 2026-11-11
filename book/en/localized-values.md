---
group: relationships
status: draft
related: [json-column, lookup-table]
---

# Localized Values

Localized values are attributes that need a separate value per language, such as a product name or a category description. The chapter compares a translation table keyed by entity and locale, per-language columns, and a JSON map of translations, and shows how to guarantee one value per locale, require the default language, and read with a fallback chain when a translation is missing. It also covers sorting and searching translated text, where collation and full-text configuration depend on the language.
