# Changelog

Notable changes, written so a person can read them. Pre-1.0, breaking changes
are expected and listed without apology.

## Unreleased

## 0.3.0 (Exchange Zone) — 2026-10-03

The write side: mutations as action values, optimistic responses as layers
that rebase under every commit, abstract types, lookups by id, and a second
sample against GitHub's API.

- Mutations. `@Mutation("…") var star: StarMutation.Action` expands to an
  action value after SwiftUI's `dismiss` and `openURL`: the compiler generates
  `callAsFunction` with one labelled parameter per variable plus
  `optimistic:`; it is `async throws`, returns the mutation's data lens, and
  `isInFlight` is observable. Mutation payloads root at
  `client:root:mutation`; the entities inside merge into their records as
  always, so a view reading a repository re-renders when a star mutation
  answers.
- Optimistic responses. The compiler generates an `OptimisticResponse`
  builder tree per mutation (every field optional, memberwise initializers).
  It renders to JSON and goes through the same ingest and plan as a server
  response, so optimistic data obeys the oracle rule and masking. The store
  keeps optimistic layers with undo logs; a commit while layers exist lifts
  them, applies the payload, re-applies them, and notifies only slots whose
  value differs in the end. The server's answer replaces its layer in one
  batch; a failure reverts it and the error is rethrown.
- Abstract types. Selections on interfaces and unions key each object by
  the payload's `__typename` (the compiler adds it to every abstract
  selection; the ingest settles the key when the typename arrives, before or
  after the id). Lenses read such selections through the record's concrete
  type; `asRepository`-style accessors and conditional spreads work. Relay's
  rule applies unchanged: a spread inside an inline fragment on an abstract
  selection needs `@alias`.
- Lookups by id across types. A lookup without a `type` (`Query.node`)
  resolves through an id index the store keeps for every entity, so
  `node(id:)` renders from the store for anything a list already fetched.
- Per-target `baton.json`: read from the target's directory first, then the
  package root, so one package holds the Rick and Morty sample, the GitHub
  sample, the tests and the benchmarks against three schemas.
- The GitHub sample (`examples/GitHubTriage`,
  `GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage`): the viewer's
  assigned and authored issues and pull requests over the `SearchResultItem`
  union, a repository screen with an optimistic star toggle, an issue screen
  with comments and reactions and a comment composer. Its schema has about
  1,800 definitions and compiles in 35 ms.
- The compiler renders constant arguments in storage keys as JSON, as
  Relay's `formatStorageKey` does (`issues(states:"OPEN")`), and escapes them
  in generated Swift; it accepts `<Operation>.Action` and module-qualified
  property types.
- `TransportError` has a public initializer, for transports and tests.

Tests: an optimistic response shows at once and is reverted when the server
fails; the server's answer replaces the layer in one batch and the mutation
returns its data; a server payload commits under a live layer and the layer
stays on top until it resolves; resolving or reverting a layer notifies only
the slots whose value differs in the end; objects behind a union are keyed by
their concrete type in either typename order; `node(id:)` finds a cached
entity by id across types.

Deliberately not added: the declarative edge directives (`@appendEdge`,
`@prependEdge`, `@deleteEdge`, `@deleteRecord`), which ship with
`@connection` in 0.4; imperative updaters; `@alias(as:)` renaming (the
directive is accepted, the accessor keeps its default name); typed input
objects (variables of input-object type are still `Baton.Variable`); a
mutation queue or offline retry (never, see the non-goals).

## 0.2.0 (First Leg) — 2026-10-02

Lifetime: the store now forgets, on purpose and on Relay's terms.

- Retained roots. A `@Query` storage retains its handle while the view lives
  and releases it when SwiftUI drops the view's state. Released handles wait
  in a release buffer (`Environment.releaseBufferSize`, default 10, oldest
  out first); retained and buffered handles are the roots that keep records
  alive.
- Collection. Mark and sweep over the roots' plans, coalesced into one pass
  per batch of releases; swept records are cleared so cycles break, and the
  root's links to them are dropped. `Environment.collect()` runs it on demand.
- Fetch policies, as `@Query("…", fetchPolicy:)`: `storeOrNetwork`,
  `storeAndNetwork` (the default), `networkOnly`, `storeOnly`. A `storeOnly`
  operation without data fails with `MissingDataError`.
- Staleness. `Environment.invalidate()` marks everything stale and refetches
  retained handles while their data stays visible; `queryCacheExpiration`
  does the same by age; `isStale` on every operation value.
- Preload parks a fetching handle in the buffer; a view attaching within the
  window finds the request in flight or the data present. Equal operation
  values share one handle and never fetch twice at once; `settle()` awaits
  the fetch in flight.
- `RecordedTransport` takes a responder closure, for tests and benchmarks that
  serve many pages.
- The compiler's scanner skips attribute arguments after the GraphQL literal.

Tests: re-entry within the buffer makes no request and eviction does;
collection removes unreachable records and keeps shared ones; each policy's
first-attach behaviour; invalidation and expiration refetch; preload. The
bench scrolls 42 synthetic pages through a buffer of 10 and reports records,
roots and footprint per page, plus the cost of a collection pass.

Deliberately not added: field-level invalidation, off-main marking, a
collection budget per pass, `holdGC` for optimistic updates (0.3).

## 0.1.0 (Starting Blocks) — 2026-10-02

The vertical spine: one query through every layer, done properly, against the
public Rick and Morty API.

- The compiler (`batonc`, Rust): finds `@Fragment`, `@Query`, `@Mutation` and
  `@Subscription` literals in Swift sources and accepts `.graphql` files;
  validates against the schema with Relay's front end (`graphql-syntax`,
  `schema`, `graphql-ir`, `relay-transforms` at v21.0.1, pinned); reports
  errors at the exact character inside the Swift string literal; emits a lens
  struct per fragment and operation (one line per field), an operation value
  per query with its text, persisted id and normalization plan as static
  data, and a per-target `Baton.baton.swift` of interned types and slots.
  Lookups in `baton.json` let a root field such as `character(id:)` be
  satisfied by a cached entity.
- The runtime (`Baton`, Swift): a `Registry` of interned types and storage
  keys; `Record` objects that drive Observation through sixteen invalidation
  channels so a body re-runs only when a field it read changes; a main-actor
  `Store` with synchronous reads, atomic commits that compare before they
  allocate or notify, and an availability check; a plan-driven `Ingest` that
  decodes response bytes into an arena change set in one pass; a
  `URLSessionTransport`; an `Environment` injected as `\.baton`; operation
  values that resolve to an `OperationHandle` with a synchronous `Phase`.
- The SwiftUI surface: `@Fragment` and `@Query` marker macros (`@Query` is an
  accessor-plus-peer macro over `OperationStorage`, so a parent passes
  variables and a body reads the resolved handle), `Baton.List` with a
  `ForEach` overload keyed by record identity, `phase`, `isRefreshing`,
  `refetch()` and `retry()` on every operation value.
- The build plugin: one `batonc generate` per target with one declared output
  per Swift file that embeds GraphQL plus the shared slots file; outputs are
  rewritten only when their content changed.
- The sample (`examples/RickAndMorty`, `swift run RickAndMorty`): characters,
  character detail, episode and location screens over one store, with the
  list prefetching the detail header so a detail renders from the store in
  its first body.
- Tests prove the two claims the release exists for: a character already in
  the store renders in the first body of its detail (through a lookup, with
  the network silent), and a commit that changes one field invalidates
  exactly one row. The response is the oracle: lens reads of the fixture
  agree with the raw JSON field for field.
- Benchmarks (`swift run -c release BatonBenchmarks`) and `BENCHMARKS.md` with
  the first recorded numbers, including the comparison with Apollo iOS 2.4 on
  the same fixture.

Deliberately not added: mutations, pagination, retention and garbage
collection, persistence, `@defer`, abstract types, `@required`/`@catch`,
enums as Swift enums (they read as `String` for now), and lists of nullable
items (null items are dropped). Each has its release on the ladder.

Known shortcuts, honest about them: a detail screen that needs more than the
list prefetched is two operations rather than one with `@defer`; variables of
input-object type are passed as `Baton.Variable`; the fetch policy is
store-and-network only.
