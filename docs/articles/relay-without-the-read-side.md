# Relay without the read side

Baton keeps Relay's compiler and the write side of its store. It deletes
the read side instead of porting it.

Half of Relay's runtime exists to answer one question React cannot answer
for itself. Which component read which field, so that a change re-renders
exactly those. SwiftUI's Observation answers that question. So does
Compose's snapshot state. Porting the machinery that answers it would have
been a second copy of something the platform already does, paid for on every
read.

## The question Relay's runtime answers

Relay's store is a flat map of records. When a component reads a fragment,
Relay walks the records and builds a snapshot of the fragment's data. It
remembers the set of records the walk touched. Those are the seen records.

When a payload is published, Relay intersects the updated record ids with
every subscription's seen records. It re-reads the snapshots that overlap.
It compares the new snapshot with the old one. It recycles the subtrees
that did not change, so references stay stable. It re-renders the
components whose snapshot changed.
When data is missing, it suspends the component by throwing a promise. A
generator-based collector sweeps records no root reaches.

None of that is GraphQL. It is the bookkeeping a runtime needs when the
framework it serves cannot report what a render read. React's render is a
function call that returns elements. Nothing on the way out says which
object's which property the function touched. So Relay built the tracking
itself. The unit it can track is the fragment, with a field-level path
behind a flag that is off by default.

## The frameworks that can answer it

SwiftUI's Observation tracks, for each body evaluation, every property of
every observable object the body read. It re-runs only the bodies whose
dependencies changed. Compose does the same through snapshot state. A read
of a state object inside a composition scope records the dependency. A write
invalidates the scopes that read it.

Apple's own guidance for a list is one small observable object per item, so
that one change re-runs one row ([the
principle](../principles/store-is-the-ui-state.md)). Those are exactly the
mechanisms a normalized store wants. A record is one small object. A field
is one property of it.

So in Baton a record is an observable object, and each of its slots is an
invalidation channel. A fragment compiles to a lens. A lens is a typed,
read-only view over one record, with one accessor per field you declared.
The accessor is where a read is registered. You read `issue.title`. That
loads the slot, and it tells the framework that this body depends on the
`title` of `Issue:42`.

A commit writes the slots that changed and notifies the fields that changed.
The runtime has no subscriptions of its own, no snapshot to build, no seen
record set to intersect, and no second copy of the data to keep equal to the
first. The body that read a field is invalidated when that field of that
record changes, and at no other time. A refetch that answers with the same
bytes notifies nothing, because the store compares before it notifies.

## What that costs, measured

The cost of tracking is Observation's, and nobody else's. On an Apple M1 Pro
with macOS 26.5.2, on 2 October 2026, a tracked lens read inside a row body
of eight fields cost 553 ns per field. The spike behind the design had
measured 534 ns for the same read, against 554 ns for a property of an
`@Observable` class ([BENCHMARKS.md](../../BENCHMARKS.md), the 0.1.0 entry).

An untracked read, outside any body, is a slot load: 26 ns. On a Google
Pixel 9, through the Kotlin runtime, a field costs 47 ns. A commit with one
field changed among twenty observed rows invalidates that one row. The base
commit and the edited commit together cost 332 µs on the Mac. The same
payload committed again, nothing changed, costs the main actor 165 µs and no
view.

The comparison that matters is with the clients that do the work by hand.
Apollo iOS and Apollo Kotlin keep a watcher per query. The watcher remembers
the field keys the query's last execution touched. A write that overlaps
re-executes the whole operation and delivers a new model tree. On iOS there
is no equality check at all.

A Netflix engineer, profiling a scrolling feed on Apollo Kotlin in August
2026, found the recomputation of watcher keys at about a third of the
cache's CPU. That is the author's own caveat, from one session on a
debuggable emulator. Relay itself still pays for the snapshot and the
re-read, because it must. Baton's bookkeeping is the framework's. The
framework was going to do it anyway, for every other piece of state in the
app.

## What stays from Relay

The parts of Relay that are about GraphQL transfer whole. They are what
Baton built first.

- The compiler's front end, pinned at a tag behind Baton's own driver, so
  the directives are parsed and validated by the code that defines them
  ([the decision](../decisions/relay-front-end.md)).
- The normalization plan. The artifact, with every fragment inlined, that
  writes a payload into flat records. Relay emits it as a JavaScript object.
  Baton emits it as a data table, in Swift and in Kotlin.
- The release buffer, ten operations by default, so that going back to a
  screen you recently left is free. The optimistic layer, rebased under later
  commits. The connection handler, which merges pages into one list. The
  four fetch policies. `@required`, `@catch`, `@throwOnFieldError`,
  `@defer`, `@stream`.
- The words. A fragment is a fragment. A connection is a connection. An
  environment is an environment. A Relay developer reads a Baton file
  without a glossary ([Relay's words](../principles/relays-words.md)).

What does not transfer is named in [Relay's
words](../principles/relays-words.md), so that nobody ports it by habit.
Snapshots and seen-record sets. Structural recycling. Suspension by thrown
promises. The generator-based collector. String-keyed records. Resolvers.
Client edges. Updatable fragments. Multi-actor stores. [Porting from
Relay](../recipes/porting-from-relay.md) puts Relay's words beside Baton's.
For what is not ported, it says why, and what would reopen it.

## The reader becomes a type

Relay's compiler already splits the two walks. The normalization artifact
inlines every fragment. The reader artifact keeps the fragment boundaries
and, at a spread, hands the child a pointer instead of the child's fields.

Baton keeps that split and turns the reader into a type. The lens is a
record reference, a context, and one accessor per declared field. A spread
compiles to an accessor that returns the child's lens. A plural field is a
lazy collection of lenses. A parent passes a child the lens, three
references, and has no accessor for the child's fields.

Masking is therefore not enforced. It is structural. The lens has no
accessor for a field the fragment did not declare, and the compiler is the
only thing that can add one. The same shape gives per-field observation,
because the accessor is where the read is registered. It also gives small
generated code, because a lens holds no storage and conforms to nothing it
does not need. One line per field. 106 bytes of source per accessor line,
over the compiler's goldens, fenced at 120 by the compiler's tests.

## Two things the spike taught

The design was measured before it was built. Two findings from that spike
are rules of the project now.

A property wrapper cannot carry the GraphQL text. An attribute's arguments
initialize the wrapper directly, so the markers are attached macros that
expand to nothing, and the compiler reads the source ([the
decision](../decisions/marker-macros.md)).

The key paths that serve as invalidation channels must have distinct bodies.
Computed getters with identical bodies are merged by the optimizer in a
release build, and their key paths then collide inside the registrar. The
spike found that the hard way. Each channel now goes through one subscript.
The tests run in release builds as well as debug, because that is the build
that shows it.

## What it refuses

A lens is valid on the main actor, where the store lives. View bodies run
there, and a cached screen has to render in its first frame. Code that needs
a value elsewhere hops there, or takes an explicit snapshot. That snapshot
is what an `@inline` fragment compiles to.

Derived state outside a view observes the store through `Observations` in
Swift and `snapshotFlow` in Kotlin ([the
recipe](../recipes/derived-state.md)). The runtime signals nothing of its
own ([the
decision](../decisions/derived-state-is-observed-not-signaled.md)).

The floor is the 26 releases of Apple's platforms, and Android 6 on Kotlin,
because the design is built on what those frameworks can see ([the
floors](../decisions/platform-floors.md)).

Those are the terms of the trade. In exchange, the data layer disappears
from product code. A fragment sits beside a body, and the data is there.
When a title changes, the `Text` that read it updates. The row beside it
does not.
