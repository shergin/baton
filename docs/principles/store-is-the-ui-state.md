# The store is the UI's state

Records are observable objects. A view body that read a field is invalidated
when that field of that record changes and at no other time. Reads are
synchronous on the main actor and cost nanoseconds; everything that is not a
read or a commit runs off it.

## Why

Relay built a subscription machine because React could not tell it which
component read which field: snapshots, seen-record sets, re-reads on overlap,
structural recycling to keep references stable. Apollo's native clients built
less and got less: watchers per query that re-execute the whole operation when
any field it read changes, with no equality check on iOS, and store reads that
are asynchronous on both platforms, so a warm cache still shows a loading
frame. One production profile found a third of all cache CPU spent
recomputing watcher keys.

The opposite failure is to do nothing: hand views plain values and let the
whole screen re-render on every response. Fast to build, impossible to scale
past a list.

## The idea

SwiftUI tracks which observable properties a body reads and re-runs only the
bodies whose dependencies changed. Compose does the same through snapshot
state. A normalized record is exactly the "one small observable object per
item" the platform recommends. So each record carries a registrar; a lens
accessor registers the read of one field of one record through a static key
path; a commit notifies changed fields of records that someone observed. The
runtime has no subscriptions of its own.

Reads are synchronous because view bodies are synchronous, and because a
cached screen must render in its first frame. The store therefore lives on
the main actor, and nothing else does: bytes are decoded and normalized on an
ingest actor, change sets are diffed against immutable slot arrays before they
reach the main actor, collection marks from a snapshot, persistence writes
behind. A commit is pointer swaps for the records that changed and
notifications for the observed fields that changed.

## Consequences

- No asynchronous read API exists for views. A handle resolves against the
  store before the first body; data that is present is present immediately.
- The store detects change before it notifies: a write of an equal value is
  not a change.
- Commits are atomic. A view never sees half a response, and an optimistic
  update that is reverted and re-applied in the same commit notifies only the
  net difference.
- `withAnimation { commit }` animates data-driven changes, because a commit is
  ordinary main-actor state mutation.
- UIKit gets the same precision through automatic observation tracking.
- The cost is Observation's and nobody else's: a tracked field read costs
  what an `@Observable` property costs; an untracked one less.

## Not this

- A store behind an actor or a lock that views must `await`.
- Query-level watchers that re-execute an operation and emit a tree.
- A subscription per fragment instance with its own bookkeeping.
- Notifying on every write without comparing values.
- Any work on the main actor besides slot reads and commits.

See [A fragment is a lens](fragment-is-a-lens.md) for where a read is
registered and [The response is the oracle](response-is-the-oracle.md) for
what a commit must preserve.

## Spelled today

`Record` is the observable object, with one invalidation channel per slot:
a key path through one subscript, made on first use and shared by every
record. `Store.commit(_ changes:)` runs on the main actor; `Ingest` decodes
off it, in the fetch's own task; `Environment` holds both. This section may
rot; the rest must not.
