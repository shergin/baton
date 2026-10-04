# A fragment has one reading: a lens, or an `@inline` value

Status: accepted, 2026-10-04. Serves
[A fragment is a lens](../principles/fragment-is-a-lens.md),
[Relay's words](../principles/relays-words.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen if a
real screen needs both readings of one fragment and cannot spread an inline
fragment beside its own, or if adopters' views start taking inline values.

## Context

A lens is live and can be read only on the main actor. Code that runs
elsewhere needs a value, and the principle says so: it "hops there or takes
an explicit snapshot". Today the snapshot is written by hand, a field at a
time, and nothing checks it against the fragment.

The first adopter asked for more
([#14](https://github.com/shergin/baton/issues/14)): a `@snapshot`
directive that makes a fragment or an operation root also emit
`Name.Snapshot`, a `Sendable` and `Hashable` struct, with `snapshot()` on
the lens. Four cases: work off the main actor, rules tested with values,
the value at the time of an action, equality by value. The issue says
Relay has no word for this. The first answer was to refuse it as a model
layer.

Relay has the word. `@inline` marks a fragment whose data a function
outside rendering reads as a plain value, through `readInlineData`, and
the value is not live. The compiler rejects `@inline` today, on purpose,
as a directive Relay's front end accepts and Baton gave no meaning.

## Decision

A fragment has one reading. Live, it is a lens, for views. Frozen, it is a
value, for code outside views.

- `@snapshot` is refused. The word, because Relay has one. The shape,
  because a value type beside the lens of the same fragment is the model
  the lens replaced: every marked view fragment would have a copy to hand
  around.
- The frozen reading is Relay's `@inline` *(planned)*. The compiler emits a
  plain `Sendable`, `Hashable` struct for the fragment: a stored property
  per field, a nested value per link, an array per plural link, and an
  initializer, so a test builds one. The spread's accessor on the parent's
  lens reads it out, on the main actor, when it is called.
- A fragment is a lens or inline, never both. No lens gets a `snapshot()`.
- An inline fragment spreads only inline fragments: a value holds no lens.
- The value is terminal. No Baton API accepts one, and `@Fragment` on a
  view's property refuses an inline fragment.
- This is the principle's explicit snapshot, generated. When it is built,
  the principle's line on generated code says that it speaks of lenses.
- It waits behind the work the adopter's other issues ask for first: the
  session, the fetch, the write path, the wire. An adopter who shows code
  off the main actor copying many fields of many fragments by hand moves it
  up. A copy of a few scalars at the call works today, and until `@inline`
  is built the compiler keeps rejecting it.

## Evidence

- Relay's documentation of `@inline` and `readInlineData`, read 2026-10-04
  ([GraphQL directives](https://relay.dev/docs/api-reference/graphql-and-directives/)):
  for functions outside rendering; a plain value, not subscribed.
- The compiler as built: `directives.rs` gives `@inline` no place, and the
  directive test `a_directive_baton_gives_no_meaning_is_an_error_at_it`
  pins the error.
- The lens as built: a `nonisolated` struct that is `Sendable`, with
  `@MainActor` accessors. It can be carried across an isolation boundary
  and read on one side of it only.
- The demand is one issue naming four cases. No call site has been shown,
  which is why the build waits.
- Not measured yet: the generated code an inline fragment adds, and what
  reading one out costs. Both are recorded when it is built.

## Not chosen

- `@snapshot` as filed: an invented word, and a second type for every
  marked fragment.
- Refusing the need, which was the first answer. Every crossing of the
  main actor's boundary stays a hand copy that nothing checks, a function
  outside a view cannot state the data it needs as a value, and a document
  a web team already wrote with `@inline` has no path here.
- Accepting `@inline` and doing nothing with it, as Relay's transforms do
  when their output is not used: a directive that compiles and means
  nothing.
- A lens readable off the main actor, or the same lens over a frozen copy
  of its records: records are the main actor's state, and a second kind of
  storage behind every accessor taxes every read.
- An untyped copy, such as the selection's JSON: nothing for a rule or a
  test to read by name.
- A flag for tracked snapshots: Observation already registers what a body
  reads, an inline value's fields among them.
