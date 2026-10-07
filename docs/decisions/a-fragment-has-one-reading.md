# A fragment has one reading: a lens, or an `@inline` value

Status: accepted, 2026-10-04. Serves
[A fragment is a lens](../principles/fragment-is-a-lens.md),
[Relay's words](../principles/relays-words.md) and
[What earns a concept](../principles/what-earns-a-concept.md). Reopen if a
real screen needs both readings of one fragment and cannot spread an inline
fragment beside its own, or if adopters' views start taking inline values.
Sharpened 2026-10-06, before the build, with the rules it gained: what an
inline fragment contains and that its spread takes Relay's directives but
`@catch`, the `Hashable` value under `@catch`, operation roots, a value
held by a view, and where a read of the value registers. The decision is unchanged.

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
  This is Baton's rule, stricter than Relay's, whose transform leaves a
  normal spread inside an inline fragment as a spread and hands back a
  fragment reference inside the data. The value is `Hashable` by value; a
  lens inside it would be equal by identity.
- The value is terminal. No Baton API accepts one, and `@Fragment` on a
  view's property refuses an inline fragment.
- Terminal does not mean never near a view. A view may hold a value as a
  plain parameter of its own initializer: a sheet given the price as of the
  tap is the intended use. What is refused is a Baton API that takes one.
- `@connection` and `@refetchable` have no meaning on a frozen value, and
  are refused on an inline fragment and inside one.
- The spread of an inline fragment takes what any spread takes but
  `@catch`: `@include`, `@skip`, `@defer`, `@arguments` and `@alias`.
  `@catch` on it is an error, as in Relay. A conditional or deferred
  spread's accessor returns an optional value, as a lens's does, so
  nothing new is needed and Relay's documents keep compiling. Relay keeps
  the spread's arguments; its IR builder lifts `@include` and `@skip` into
  a condition around the spread, and its defer transform, which runs before
  the inline transform, lifts `@defer` the same way; `@catch` stays on the
  spread and is refused there. A restriction Relay does not have needs a
  reason, and there is none. The spread table in `directives.rs`
  (`SPREAD`) gains a branch that refuses `@catch` on an inline fragment's
  spread when this is built.
- The value is `Hashable` unconditionally, and `@catch` breaks that as
  built: a caught field reads as a `Result` whose failure is `FieldErrors`,
  which is not `Hashable`. Open for the build: `FieldErrors` gains
  `Hashable`, which is the proposal, or the value's conformance is
  conditional.
- An operation root is not inline. `@inline` marks a fragment definition
  only, in Relay and here. A query that needs its answer as a value spreads
  one inline fragment at its root and calls that accessor on the main
  actor.
- The spread's accessor reads the value when it is called, so only a body
  that calls it depends on the inline fields, and a tap handler that calls
  it registers nothing. Relay reads inline data with the parent fragment,
  so the parent subscribes to those fields and re-renders when they change.
  The departure is on purpose: the accessor is where a lens registers a
  read.
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
- Relay's `inline_data_fragment` transform at the pinned revision, read
  2026-10-06. `validate_inline_spread_directives` rejects every directive
  on an inline fragment's spread but `@alias` and
  `@dangerously_unaliased_fixme`. The transform recurses into inline
  fragments only, so a normal spread inside one stays a spread; it rejects
  a cycle of inline fragments; it replaces the spread with the fragment's
  selections, which is why the parent's read covers them; and
  `InlineDirectiveMetadata` keeps the spread's `arguments` and the
  fragment's `variable_definitions`. Its fixtures `alias`,
  `dangerously_unaliased`, `recursive` and `variables` show the two allowed
  directives, nesting, and arguments. `@include` and `@skip` never reach
  the check: Relay's IR builder lifts them into a condition around the
  spread (`recursive` spreads one under `@include`), and its defer
  transform, which runs earlier, lifts `@defer` the same way.
- Relay's directive definitions at the same revision:
  `directive @inline on FRAGMENT_DEFINITION`.
- `FieldErrors` as built (`Errors.swift:45`) is `Error` and `Sendable` but
  not `Hashable`; `FieldError` (line 9) is `Hashable`.
- The demand is one issue naming four cases. No call site has been shown,
  which is why the build waits.
- Not measured yet: the generated code an inline fragment adds, and what
  reading one out costs. Both are recorded when it is built.

## Not chosen

- `@snapshot` as filed: an invented word, and a second type for every
  marked fragment.
- Refusing conditions and `@defer` on an inline fragment's spread, which
  Relay allows, for no reason a document would show.
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
