---
group: domain-structures
status: draft
related: [role-object, class-table-inheritance]
---

# Party

A party is the common supertype of people and organizations, so customers, suppliers, employees and partners are all parties and the rest of the schema refers to one table. Addresses, contacts, agreements and payments then attach to a party once instead of being duplicated for every kind of counterpart, and the same company can be both a supplier and a customer without becoming two records. The chapter shows the party, person and organization tables, relationships between parties, and the point where a single party table becomes more abstraction than the domain needs.
