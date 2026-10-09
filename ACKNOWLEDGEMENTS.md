# Acknowledgements

Before a line of this was written, we read the GraphQL client field across
native, web and cross-platform, and the native data layers that large apps
built for themselves. The names below are not a courtesy list. Each project
taught this one something specific, and the line says what it was.

## The model

- **Relay** (Meta) — the whole idea: fragments as the unit of data
  declaration, compile-time aggregation, data masking, a normalized store,
  reference-counted retention with a release buffer, optimistic updates that
  rebase, `@connection`, `@refetchable`, `@required`, `@catch`. Baton uses
  Relay's directive vocabulary on purpose and consumes the Relay compiler's
  front-end crates. Also the lesson, from reading its runtime, of what is
  React's rather than GraphQL's: snapshots, seen-record sets, structural
  recycling and suspension by thrown promises exist because React could not
  know which component read which field. SwiftUI and Compose can.
- **The GraphQL specification and working group** — the fragments section
  rewritten as one consumer's evolving data needs, and the Golden Path
  initiative naming normalized caching, colocation, masking, trusted
  documents and code generation as the marks of a successful deployment.

## The fixtures

- **Relay's runtime tests** (Meta, MIT) — `spec/relay/` holds cases
  harvested from Relay v21.0.1's `RelayResponseNormalizer-test.js`: its
  documents, payloads and expected records, translated into Baton's keys,
  and its `testschema.graphql` with the client extensions. Relay's own
  statement of what a normalized store holds is the second oracle Baton's
  store is held to.

## Native predecessors and neighbours

- **Relay.swift** (Matt Moriarity) — proof that the full model runs on
  SwiftUI with property wrappers, `graphql("""…""")` literals and generated
  key types, done in 2020 with weaker tools than exist today; and a warning
  about depending on a compiler plugin API one does not own.
- **Apollo iOS** and **Apollo Kotlin** — the incumbents, read in source. From
  iOS: the cost of dictionary-backed models, one JSON blob per record, and
  reads that cannot be synchronous. From Kotlin's new normalized cache:
  declarative key configuration with the compiler adding key fields and
  typenames, connection pages merged into one stored list, a memory cache in
  front of SQL, and errors stored beside data for partial reads.
- **Graphaello** (Mathias Quintero) — fragments derived from property
  wrappers on SwiftUI views; the colocation instinct, before macros.
- **cachebay-ios** — locks rather than actors so that reads stay
  synchronous, callbacks fired outside the lock, and cache plans emitted by a
  compiler so the runtime never parses GraphQL.
- **Isograph** (Robert Balicki) — components as fields on the graph, so the
  compiler generates the plumbing; `@loadable` as a cleaner unit than
  refetchable fragments plus entry points; dropping the global-id
  requirement.
- **Houdini** — the compile step inside the build system rather than a
  separate watcher, and both cursor and offset pagination.
- **urql Graphcache** — records keyed by typename plus id, embedded entities
  keyed by their path, layered optimistic updates.

## How large native apps did it

- **Meta engineering** — immutable fragment-shaped models and a consistency
  engine (2014); FlatBuffers read straight from storage, 35 ms to 4 ms per
  story (2015); the static, server-persisted operations that native apps had
  before Relay Modern borrowed them; QUIC for GraphQL requests; and Pando,
  the internal Relay-like native framework whose public description set the
  bar for generated typed accessors over immutable data.
- **LinkedIn engineering** (RocketData, ConsistencyManager) — a pub/sub
  consistency manager over immutable model trees keyed by id, a memory-mapped
  key-value store chosen for read speed, and the rule that an unreadable
  cache entry is a miss, so there are no migrations.
- **Threads (Meta)** — the number that prices the first frame: 0.29–0.36 s of
  added navigation latency cost 0.54–0.81% of daily active users.
- **Netflix, Reddit, Vrbo, Medium** — what breaks in production: identity
  without stable keys, staleness that clients serve as truth, cache misses
  after a key-generator change.

## The platform

- **Apple's Observation framework** and the WWDC25 guidance of one small
  observable object per list item, which is exactly what a normalized record
  is; **SwiftData's `@Query`** and **Core Data's `@FetchRequest`**, the
  idiom a main-actor `DynamicProperty` data handle follows.
- **Point-Free** (swift-sharing, swift-perception, SQLiteData) — driving an
  `ObservationRegistrar` by hand for externally stored values, and re-issuing
  notifications on the main thread after background writes.
- **Jetpack Compose's snapshot system** — the primitive a fine-grained store
  needs on Android, and strong skipping, which rewards small stable fragment
  references.
- **swift-openapi-generator, swift-protobuf, SwiftLint** — how a build-tool
  plugin ships a prebuilt binary in an artifact bundle, what breaks when
  generated code inherits a module's default actor isolation, and why a CLI
  mode must exist beside the plugin.

## The name

In a relay the baton is what is handed over. The word was chosen for that,
and because Relay deserved a sibling named for the race, not the company.
