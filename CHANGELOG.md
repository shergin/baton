# Changelog

Notable changes, written so a person can read them. Pre-1.0, breaking changes
are expected and listed without apology.

## Unreleased

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
