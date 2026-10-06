# Derived state is observed, not signaled

Status: accepted, 2026-10-11. Answers Caton's notes 2, B and K, which asked
twice for a commit signal a model could observe, and the plan's D-N18.
Serves [What earns a concept](../principles/what-earns-a-concept.md) and
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if a model is shown that must know a commit happened and cannot say
what it reads.

## Context

A view re-renders when a lens's field it read changes, through Observation.
A model that is not a view, a badge count or a sort, wanted the same, and
asked for a signal: a closure or a stream the store calls after each commit,
from which the model would recompute. The floor has `Observations`, a
transactional sequence over what a closure reads, which the platform-floors
record names.

## Decision

No signal. A model derives its value inside an `Observations` closure over
the lenses and handles it reads, holds the retention that keeps that data
alive, and republishes the derived value as its own observable property.
The sequence yields once per transaction that changed anything the closure
read, after the commit's notifications, and not otherwise. The recipe
[Derived state outside views](../recipes/derived-state.md) is the guide;
[UIKit and AppKit](../recipes/uikit.md) is the same pattern for a controller.

## Evidence

A test holds a fragment lens over a committed record outside any view and
observes one field through `Observations`: a commit that changes the field
yields once with the new value, and a commit that changes another field of
the same record yields nothing. That is what a signal would have had to
filter by hand.

## Not chosen

- A commit signal on the environment. It would fire for every commit, and
  every model would filter it by re-reading, which is what Observation does
  once for all of them.
- Derived fields in the store, Relay's resolvers. Logic in the store is
  refused by [the client-data decision](client-data-is-described-and-committed.md).
