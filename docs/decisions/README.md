# Decisions

Choices made among real alternatives, with the evidence that decided them
and the condition that would reopen them. One file per decision.

These are not principles. Principles are rules that must not rot; a decision
may be superseded, and says so in its status line. A decision never overrides
[vision](../vision.md) or a [principle](../principles/); where a principle
rests on a decision, the principle names it.

Each record has the same shape: a status line (accepted or superseded, with
the date, the principle it serves, and what would reopen it), then Context,
Decision, Evidence, Not chosen. Keep them short; the argument belongs in the
principle, the proof belongs here.

- [Native runtimes, not a shared core](native-runtimes.md)
- [Relay's front end, pinned, behind our driver](relay-front-end.md)
- [The report is what a dependent target's compilation would read](the-report-is-what-a-dependent-target-reads.md)
- [The environment logs value-free events](the-environment-logs-value-free-events.md)
- [Derived state is observed, not signaled](derived-state-is-observed-not-signaled.md)
- [Marker macros carry the GraphQL](marker-macros.md)
- [Floors at the 26 releases](platform-floors.md)
- [Lookups satisfy root fields from cached entities](lookups.md) (superseded)
- [Connections reference page edges and own inserted ones](connections-own-their-edges.md)
- [Relay's error directives in Swift's terms](error-directives-in-swift.md)
- [The image is the system's SQLite](the-image-is-sqlite.md)
- [Slots are numbered by the process, not by the compiler](slots-are-numbered-by-the-process.md)
- [A deletion is announced by its commit, not tracked by readers](deletion-is-announced-by-its-commit.md)
- [A lookup binds in the availability check, never in a read](lookups-bind-in-the-check.md)
- [The availability check and collection run on the main actor](the-check-and-collection-run-on-the-main-actor.md)
- [The environment is the session](the-environment-is-the-session.md)
- [An image belongs to one store](an-image-belongs-to-one-store.md)
- [The image's file is protected at creation and waited for when locked](the-images-file-is-protected-and-waited-for.md)
- [The store owns roots and ages](the-store-owns-roots-and-ages.md)
- [A fragment has one reading: a lens, or an `@inline` value](a-fragment-has-one-reading.md)
- [A mapped scalar is a fallible read](a-mapped-scalar-is-a-fallible-read.md)
- [An operation is sent as its text or its id, and the build decides](an-operation-is-sent-as-text-or-id.md)
- [Client data is described by the schema and written by a payload](client-data-is-described-and-committed.md)
- [An operation states its expiration in its document](an-operation-states-its-expiration.md)
- [Keys a session produces belong to its store](session-keys-belong-to-the-store.md)
- [The store numbers what its session renders](the-store-numbers-what-it-renders.md)
- [A list's null elements are typed as the schema says](a-lists-null-elements-are-typed.md)
- [A storage key leaves a null argument out](a-storage-key-leaves-a-null-argument-out.md)
- [One runtime module, with edges as targets and a checked rule inside](one-runtime-module.md)
- [The emitter writes Swift from typed pieces, not strings](the-emitter-writes-typed-pieces.md)
- [A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md)
- [A failure says its kind](a-failure-says-its-kind.md)
- [The decided architecture is built first, one release a step](the-decided-architecture-is-built-first.md)
