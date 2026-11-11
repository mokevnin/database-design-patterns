---
group: identity
status: draft
related: [surrogate-key, time-ordered-identifier]
---

# Public Identifier

A public identifier is the ID that leaves the database — in URLs, API responses, support tickets and logs. The chapter weighs exposing the internal key against adding a separate external identifier: a sequential integer reveals business volume and invites enumeration, while a separate random or prefixed ID such as `cus_...` can name the object kind, be rotated, and stay out of joins. It shows how to store and index the external ID, how to resolve it to the internal key, and why a published ID is a contract that is hard to take back.
