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
- [The image evicts by launch before it starts over](the-image-evicts-by-launch.md)
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
- [An operation's text is printed compact](operation-text-is-printed-compact.md)
- [Client data is described by the schema and written by a payload](client-data-is-described-and-committed.md)
- [An operation states its expiration in its document](an-operation-states-its-expiration.md)
- [Keys a session produces belong to its store](session-keys-belong-to-the-store.md)
- [The store numbers what its session renders](the-store-numbers-what-it-renders.md)
- [A list's null elements are typed as the schema says](a-lists-null-elements-are-typed.md)
- [A storage key leaves a null argument out](a-storage-key-leaves-a-null-argument-out.md)
- [One runtime module, with edges as targets and a checked rule inside](one-runtime-module.md)
- [The emitter writes Swift from typed pieces, not strings](the-emitter-writes-typed-pieces.md)
- [A plan declares each of its selections once](a-plan-declares-each-selection-once.md)
- [A handle keeps its fetch and derives its phase](a-handle-derives-its-phase.md) (superseded in part)
- [The phase stays stored, beside the fetch](the-phase-stays-stored.md) (superseded in part)
- [Revalidation is one call the app makes, and the policy stays with its holder](revalidation-is-the-apps-call.md)
- [Identity is the fields the configuration names](identity-is-configured.md)
- [A mapped scalar converts at the read](a-mapped-scalar-converts-at-the-read.md)
- [An enum reads as a generated enum with an unknown case](an-enum-reads-as-a-generated-enum.md)
- [What may reach the image is a property of types and root fields](what-may-reach-the-image.md)
- [A subscription reconnects in its handle, by a fixed backoff](subscriptions-reconnect-in-the-handle.md)
- [A failure says its kind](a-failure-says-its-kind.md)
- [The decided architecture is built first, one release a step](the-decided-architecture-is-built-first.md)
- [Releases are frequent and named for bread](releases-are-frequent-and-named-for-bread.md)
- [The verdict is the root's, and the phase is derived from it](the-verdict-is-the-roots.md)
- [A payload is bytes in a response's shape](a-payload-is-bytes-in-a-responses-shape.md)
- [A mapped scalar's host type is named per language](a-mapped-scalars-host-type-is-named-per-language.md)
- [The Kotlin runtime is common first, and a platform is an actual](the-kotlin-runtime-is-common-first.md)
- [A format is per emitter](a-format-is-per-emitter.md)
- [The Kotlin host marks a document on the composable](the-kotlin-host-marks-a-document-on-the-composable.md)
- [swift-syntax spans the floor to the newest release](swift-syntax-spans-the-floor-to-the-newest.md)
