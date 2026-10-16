# The store is the UI's state

Records are observable objects. A view body that read a field is invalidated
when that field of that record changes, and at no other time.

Reads are synchronous on the main actor and cost nanoseconds. The main actor
reads, commits, checks what the store holds, collects, and normalizes an
optimistic response. Decoding and normalizing a response, and the image's
writes, run off it.

## Why

Relay built a subscription machine because React could not tell it which
component read which field. It kept snapshots and seen-record sets. It
re-read on overlap. It recycled structure so references stayed stable.
Apollo's native clients built less and got less. Watchers per query
re-execute the whole operation when any field it read changes, with no
equality check on iOS. Store reads are asynchronous on both platforms, so a
warm cache still shows a loading frame. One production profile found a third
of all cache CPU spent recomputing watcher keys.

The opposite failure is to do nothing: hand views plain values, and let the
whole screen re-render on every response. Fast to build. Impossible to scale
past a list.

## The idea

SwiftUI tracks which observable properties a body reads, and re-runs only
the bodies whose dependencies changed. Compose does the same through
snapshot state. A normalized record is exactly the "one small observable
object per item" the platform recommends. So each record carries a
registrar. A lens accessor registers the read of one field of one record
through a static key path. A commit notifies changed fields of records that
someone observed. The runtime has no subscriptions of its own.

Reads are synchronous because view bodies are synchronous, and because a
cached screen must render in its first frame. The store therefore lives on
the main actor, with the work that has to touch its records. That work is
the commit, the availability check, which reads the image when memory lacks
a record, and collection. One more thing runs there by design. An optimistic
response, a value the call passes, is normalized on the main actor, so its
layer shows in the same turn as the call rather than a frame later. Nothing
else does. A response's bytes are decoded and normalized off the main actor,
in the fetch's own task, and the image is written behind. A commit writes
the slots that changed and notifies the observed fields that changed. Why
the check and collection stay on the main actor, and the numbers that keep
them there, is
[a decision of its own](../decisions/the-check-and-collection-run-on-the-main-actor.md).

## Consequences

- No asynchronous read API exists for views. A handle resolves against the
  store before the first body. Data that is present is present immediately.
- The store detects change before it notifies. A write of an equal value is
  not a change.
- Commits are atomic. A view never sees half a response. An optimistic
  update that is reverted and re-applied in the same commit notifies only
  the net difference.
- `withAnimation { commit }` animates data-driven changes, because a commit
  is ordinary main-actor state mutation.
- UIKit gets the same precision through automatic observation tracking.
- The cost is Observation's and nobody else's. A tracked field read costs
  what an `@Observable` property costs. An untracked one costs less.

## Not this

- A store behind an actor or a lock that views must `await`.
- Query-level watchers that re-execute an operation and emit a tree.
- A subscription per fragment instance with its own bookkeeping.
- Notifying on every write without comparing values.
- Any work on the main actor besides reads, commits, the availability check,
  collection and an optimistic response's normalization, or any of those
  growing past a frame.

See [A fragment is a lens](fragment-is-a-lens.md) for where a read is
registered, and [The response is the oracle](response-is-the-oracle.md) for
what a commit must preserve.

## Spelled today

`Record` is the observable object, with one invalidation channel per slot.
That channel is a key path through one subscript, made on first use and
shared by every record. `Store.commit(_ changes:)` runs on the main actor.
`Ingest` decodes off it, in the fetch's own task. `Environment` holds the
store and runs the ingest for its fetches. This section may rot. The rest
must not.
