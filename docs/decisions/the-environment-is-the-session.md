# The environment is the session

Status: accepted, 2026-10-04. Serves
[What earns a concept](../principles/what-earns-a-concept.md) and
[Honest data](../principles/honest-data.md). Reopen if an adopter shows an
app that cannot replace the environment at its root, or data that has to
outlive a change of identity.

## Context

An app with accounts holds data that belongs to one of them. After a
sign-out none of it may stay readable: not in memory, not on disk, not
through a response that lands late. The first adopter asked for this
([#9](https://github.com/shergin/baton/issues/9)) and proposed
`Environment.replaceStore`: one environment for the life of the app, its
store swapped at sign-in and sign-out, and a generation on the store so
that work begun under the old one commits nothing.

As built, the other answer is half there. `Environment.store` is a `let`,
the README's sign-out makes a new environment, and a view's storage
resolves its operation again when the environment it sees is another one.
The far end is missing: an environment can be made and cannot be ended.
Dropping it is not an end. A handle, a lens, a fetch in flight or an open
subscription keeps it or its store alive, and readable. Records that link
to each other are freed only by a sweep, so a dropped store leaves them in
memory. And the image cannot tell when a store is done with its file, so
it outlives its stores and fences the old one with a count of removals.

## Decision

A session is the life of one environment: one identity's view of one
backend. It is not a concept of its own, and the runtime has no type for
it.

- An environment pairs a store with the transport that fills it, for life.
  Neither is replaced. A sign-in makes an environment and a sign-out ends
  it. Which one is current is the app's state: the app injects it, and the
  storage behind `@Query`, `@Mutation` and `@Subscription` follows.
- `Environment.end()` (built 2026-10-06) ends it, once and for good: it cancels
  every fetch and stream the environment started, drops the roots, clears
  every record and closes the image. What becomes of the file is
  [a decision of its own](an-image-belongs-to-one-store.md).
- An ended store commits nothing, checked at the one door a payload takes.
  That covers what
  cancellation cannot reach: a fetch the app awaits in a task of its own,
  and a mutation in flight, which is never cancelled because the server
  applies it anyway.
- What is still held says so. A handle reads
  `.failed(EnvironmentError.gone)` and tells its observers, so an owner
  outside SwiftUI resolves again in the current environment. A lens still
  held finds its records cleared. Every later call on the environment
  fails with the same error.
- A store clears its records when it is deallocated, so an
  environment dropped without an end leaks nothing. That is a net, not the
  end: the moment is not defined while anything holds the store.
- A refreshed credential is the same identity and the same environment.
  Today the built-in transports take their headers once, so an app whose
  token rotates brings its own transport.

The end does not reach the process's table of slots, which keeps the text
of every key rendered from variables, an id or a search string among them,
for the life of the process
([Slots are numbered by the process](slots-are-numbered-by-the-process.md)).

## Evidence

- A probe built from the runtime's sources (2026-10-04, Apple M1 Pro,
  macOS 26.5.2, Swift 6.3.3; kept in the planning notes): a response whose
  two records link to each other is committed and the store dropped. The
  store is freed and both records stay. Swept first, both are freed.
- The lifetime tests. "A handle whose environment is gone keeps
  its data and stops loading instead of hanging": one retained handle
  keeps a store, and its data, past its environment. "A view whose
  environment is replaced resolves its operation again in the new one":
  views follow with no help from the app.
- The runtime as built, by reading: a fetch's task holds its environment
  until it finishes, a subscription's for as long as its stream is open,
  and a mutation's request runs in a task nothing cancels.
- The image as built shows what a generation costs: one image serves
  successive stores, so eight of its functions take the count of removals
  a store noted when it was made.
- Relay was asked for a store reset at logout
  ([facebook/relay#233](https://github.com/facebook/relay/issues/233)).
  The issue's own plan is new environment instances, and Relay's earlier
  documentation of the environment advised a new one when a user logs in
  or out.
- Not measured yet: the end clears every record on the main actor. Its
  cost at 50,000 records goes into `BENCHMARKS.md` before `end()` ships.

## Not chosen

- `Environment.replaceStore`. A store holds what its transport's
  credentials were allowed to see, so the two change together or one
  account's response lands in another's store. Every write path then
  checks a generation, and what is left of the environment is an address,
  which SwiftUI's environment already is. A handle that keeps its identity
  across accounts shows one account's data and then another's.
- A generation, or a retired flag, carried by work in flight. An object
  that serves sessions in turn needs one. An object that serves one
  session needs a terminal state, checked where a change set reaches the
  main actor.
- Emptying the store in place: the transport, the work in flight and every
  handle stay from before. It is `replaceStore` by another name.
- A session type, or a manager of environments, in the runtime: who is
  signed in is the app's state, and the runtime would hold a pointer the
  app already holds.
- `invalidate()`, `close()` or `dispose()` as the verb. Relay has none,
  because JavaScript collects an environment nobody holds. `invalidate` is
  taken by Relay's meaning, data marked stale; `close` is the image's;
  `dispose` is Relay's word for one holder letting go, `release()` here.
