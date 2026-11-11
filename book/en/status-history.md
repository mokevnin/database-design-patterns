---
group: reference-and-state
status: draft
related: [lookup-table, history-table, audit-log, version-column]
---

# Status History

Status history keeps the current state of an entity — an order, a ticket, an application — together with a log of every transition: from which state, to which, when, by whom and why. A table of allowed transitions, referenced by a foreign key, rejects moves the process does not permit, such as going from `shipped` back to `draft`. The chapter shows how to write the current status and the history row atomically, why a foreign key alone cannot check that a transition starts from the actual current state, and which locking closes that gap under concurrent updates.
