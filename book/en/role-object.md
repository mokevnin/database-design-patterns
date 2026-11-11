---
group: domain-structures
status: draft
related: [party, effective-dating]
---

# Role Object

A role object stores each role a party plays — customer, supplier, employee, account manager — as a separate row with its own attributes and validity period, instead of boolean flags or rigid subtypes. A person can hold several roles at once, gain and lose them over time, and each role carries the data that belongs to it, such as a customer's credit limit. The chapter covers the role table, role-specific detail tables, constraints on which roles may combine, and relationships between parties expressed through their roles.
