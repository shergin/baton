# A lookup binds in the availability check, never in a read

Status: accepted, 2026-10-03; supersedes
[Lookups satisfy root fields from cached entities](lookups.md). Serves
[The store is the UI's state](../principles/store-is-the-ui-state.md). Reopen
if a lens must render a root field that no availability check has walked,
such as a lens built over the root by hand outside an operation.

## Context

`baton.json` names root fields that return an entity by one of their
arguments, and the plan carries each lookup. Until now two places bound a
lookup: the availability check, before a handle is ready, and the lens read
of a missing root link, which resolved the entity and wrote the link. The
second is a write inside a view body: the body that reads the field writes
the slot it is reading and notifies the channel it has just registered on,
while it renders. The check writes the link too, outside any commit, but
before the handle it serves is ready, so no body has read the slot yet.

## Decision

Only the availability check binds a lookup. A handle is ready only after the
check has walked the operation's selection, so by the time a body reads a
root field the check has either written the link to the cached entity or
reported the data incomplete, and the fetch writes the link from the
response. A lens read of a missing link reads nil and reports missing data,
as for any other field. The generated accessors take no lookup; the
`lookup:` parameters of `linked`, `requiredLinked` and `throwingLinked` and
`Store.resolveLookup` are gone.

The configuration, the plan's lookups, the rule for a lookup without a type
(one live record among the field's possible types) and the image's part
(an entity only the image holds satisfies a lookup that names its type) are
as the superseded record says.

## Evidence

- The spine's first-body test is unchanged: a detail whose root field was
  never fetched is `.ready` on creation, rendering the entity the list
  fetched, because the handle's check binds the link.
- A new spine test reads the root field before any check: nil, with the
  miss reported, and the link still missing; after the check the same lens
  reads the entity.
- The two other tests that relied on the read-side write, each a lens
  built over the root by hand, now run the check first, as a handle does.

## Not chosen

- Keeping the read-side binding: a write and a notification during
  rendering, with no undo and no commit, for a case a handle never reaches.
- Turning the binding into a commit through the store's transaction: the
  link needs no undo and no row in the image, and a commit from a read is
  still a write from a read.
