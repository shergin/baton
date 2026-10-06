<p align="center">
  <img src="baton.png" alt="A loaf of bread, drawn in one line: the Baton logo" width="160">
</p>

# Baton 🥖

**Baton brings Relay to SwiftUI and Compose.** A fragment beside every view,
one request per screen, cached data in the first frame, and a re-render only
where a field changed.

A view declares the GraphQL fragment it reads, beside its body. The compiler
aggregates the fragments of a screen into one operation, validates everything
against the schema at build time, and emits a small typed lens per fragment.
The runtime normalizes responses into records that the UI framework itself
observes.

Baton is aligned with Relay, not Apollo: the same directives, the same
conventions, the same compiler lineage. A team running Relay on the web and
Baton on native speaks one language. Where Relay's design is React's rather
than GraphQL's (snapshots, re-reads, suspension by thrown promises), Baton
leaves it out: SwiftUI's Observation and Compose's snapshot state already know
which view read which field.

The design is in [`docs/vision.md`](docs/vision.md). Constraints it assumes
live in [`docs/principles/`](docs/principles/). The vocabulary is
[`docs/terminology.md`](docs/terminology.md). How this compares with the
other native clients is at the end, and at length in
[`docs/comparison.md`](docs/comparison.md).

## What it is, and will be

- **A fragment per view.** GraphQL lives in the Swift file, next to the view
  that reads it, as a full, valid document. A parent passes a child its
  fragment as a record reference and a context; a child can read nothing it
  did not declare.
- **One request per screen.** The compiler assembles the operation from the
  fragments spread into it and emits a persisted id for it. Nobody writes the
  screen's query by hand, and nothing waterfalls.
- **Cached data in the first frame.** Reads are synchronous on the main
  actor; a handle resolves against the store before the first body runs, and
  after a launch the store reads what that handle needs from its image on
  disk. Decoding and normalizing a response and the image's writes run off
  it; the check and garbage collection stay on it, each under a third of a
  frame on the benchmark machine, and an optimistic response is normalized
  on it, so its layer shows in the turn of the call.
- **Only changed views re-render.** Records are observable objects; a body
  that read `user.name` is invalidated when that field of that record changes
  and at no other time. An unchanged refetch of the benchmark fixture costs
  the main actor under 200 µs and no view; committing all 899 records costs
  about a millisecond.
- **Honest data.** Nullability is what the schema says; `@required` and
  `@catch` work as in Relay, in Swift's terms (an optional lens, a `Result`,
  a `get throws`); field errors survive caching; staleness is a phase a view
  can read.
- **Small everything.** Generated code is one line per field plus data
  tables. The runtime depends on Foundation, Observation and the SQLite the
  system ships. The compiler is one prebuilt binary, shared by the Swift and
  (later) Kotlin runtimes.
- **Declarative, down to the writes.** What a view needs, how a list pages,
  what an optimistic response shows and how a mutation edits a list are all
  directives and values in the GraphQL text beside the view; nothing is
  wired up at run time. That is also what makes Baton cheap for code that
  language models write: one file holds the whole contract, the build checks
  it against the schema at the exact character, and a wrong field is a
  compile error rather than a runtime surprise.

## What it will not be

- Not a runtime GraphQL client: every operation is known at build time. No
  query builders, no string queries, no GraphQL parser in the app.
- Not a model layer: there is nothing decoded to hold, mutate or persist
  besides the store itself.
- Not configurable by policy objects: identity is schema configuration
  compiled in; behaviour is a directive or a value on a handle.
- Not an offline-sync engine, a local-state framework, a server, or a React
  Native or web client.
- Not one runtime for two platforms: the Swift and Kotlin runtimes are
  separate and idiomatic; the compiler, the artifact format, the vocabulary
  and the conformance fixtures are shared.

## The feel

From the sample; the API will still move before 1.0.

```swift
struct CharacterRow: View {
    @Fragment("""
        fragment CharacterRow_character on Character {
          name
          status
          image
        }
        """)
    var character: CharacterRow_character

    var body: some View {
        HStack {
            Avatar(url: character.image)
            Text(character.name ?? "Unknown")
            Text(character.status ?? "")
        }
    }
}

struct CharactersScreen: View {
    @Query("""
        query CharactersScreenQuery($page: Int) {
          characters(page: $page) {
            results { id ...CharacterRow_character }
          }
        }
        """)
    var characters: CharactersScreenQuery

    var body: some View {
        switch characters.phase {
        case .ready(let data):
            List {
                ForEach(data.characters?.results ?? []) { character in
                    CharacterRow(character: character.characterRow)
                }
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { characters.retry() }
        }
    }
}
```

A list is a Relay connection. The fragment owns the pagination, the store
owns the merged pages, and the view reads them like any other field:

```swift
struct IssueList: View {
    @Fragment("""
        fragment IssueList_repository on Repository
        @refetchable(queryName: "IssueListPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 20}, cursor: {type: "String"}) {
          issues(first: $count, after: $cursor, states: OPEN) @connection(key: "IssueList_issues") {
            edges { node { id ...IssueRow_issue } }
          }
        }
        """)
    var repository: IssueList_repository

    var body: some View {
        ForEach(repository.issues.nodes) { issue in
            IssueRow(issue: issue.issueRow)
        }
        if repository.issues.hasNext {
            ProgressView().task { try? await repository.issues.loadNext() }
        }
    }
}
```

## Written by people, or by models

A screen written by a language model has the same shape as one written by a
person, and goes through the same checks. The fragment beside the view is
complete, valid GraphQL; the schema decides what exists; the generated lens
decides what the body may read; the directives decide how data moves
(`@connection`, `@appendEdge`, `@required`, `@catch`). There is no cache
policy to configure, no normalizer to teach and no updater function to write,
so there is nothing a generator has to know that is not in the file in front
of it. The vocabulary is closed and short
([`docs/terminology.md`](docs/terminology.md)) and fits in a prompt; the
compiler's diagnostics point at the character in the GraphQL text that is
wrong, which is the feedback a model iterates on best. The result is code
that is quick to generate, easy to review, and hard to get silently wrong.

## Status

0.6.0 (Anchor Leg). Reads, writes, lists, errors and persistence run through
every layer, with tests and benchmarks behind the claims: cached data in the
first body, one changed field re-rendering one row, memory bounded by a
release buffer rather than by how far the user scrolls, optimistic responses
that show at once, rebase under every commit and revert on failure,
connections that merge their pages in the store and grow by one notification
per page, field errors stored beside their fields and read through Relay's
directives, deferred fragments that arrive after the first frame,
subscriptions, and a store that outlives the process. A launch draws the
screens it showed last time from disk, before the network answers. The API
will break freely until 1.0.

- **0.1.0 (Starting Blocks).** The compiler over Relay's front end, lens
  types, the observable store, the one-pass ingest, `@Fragment` and `@Query`
  for SwiftUI, lookups, the Rick and Morty sample.
- **0.2.0 (First Leg).** Retained roots, the release buffer, collection, the
  four fetch policies, invalidation and expiration, preload.
- **0.3.0 (Exchange Zone).** `@Mutation` as an action value, optimistic
  layers, abstract types, lookups by id across types, the GitHub sample.
- **0.4.0 (Hand-off).** `@connection` with merged pages and `loadNext`,
  `@refetchable`, fragment arguments, `@alias(as:)`, the edge directives.
- **0.5.0 (Baton Pass).** Field errors beside their fields, `@required`,
  `@catch`, `@throwOnFieldError` with `@semanticNonNull`, `onError`, `@defer`
  over the incremental formats, subscriptions over `graphql-transport-ws`.
- **0.6.0 (Anchor Leg).** The store's image on disk through the system's
  SQLite, written behind every commit and read back by the availability
  check, with ages that survive a launch.
- **0.7.0 (Split Time).** The ground before the spine: the runtime's
  boundaries checked as a ratchet, the test transports in `BatonTesting`,
  lists of lists refused by the compiler, the plugin's inputs and outputs
  told truly, the hostile-name sweep in CI, the numbers the next steps are
  measured against, and the first published compiler bundle.

Still to come: the architecture the [decision records](docs/decisions/)
describe, built
[one release a step](docs/decisions/the-decided-architecture-is-built-first.md),
then the road to 1.0. Each release is described in full in
[`CHANGELOG.md`](CHANGELOG.md).

## Using it

Add the package and the plugin to a target, put `baton.json` with the schema
path (and the identity of types not keyed by `id`, lookups, and `onError`
if the server takes it) in the target's directory or at the package root,
and build. The plugin runs `batonc` for every Swift file that declares
GraphQL and reports schema errors at the GraphQL text. The generated files import
the runtime's interface for generated code, `@_spi(Generated) import
Baton`; the app's own files import `Baton` and need nothing more. Tests and
previews add `BatonTesting`, a second product of the package, for a
transport that answers from recorded responses.

To keep the store across launches, give the environment an image:
`Environment(url: endpoint, persistence: Persistence(name: "Main", version: Types.schemaDigest))`,
where `Types.schemaDigest` is the generated digest of the schema, so a new
schema starts the image again. `protection:` gives the file the platform's
protection class at its creation; under `.complete` the writer waits for a
locked file rather than lose its work. A sign-out is `await environment.end()`,
which cancels what the environment started, clears its records and closes
the image, then `removeAll()` on the image, which the next open finishes if
a crash interrupts it, then forgetting the credential; the next environment
makes its own image, on that file or another. A
response that lands late for the user who signed out reaches neither memory
nor the image, and a handle a model still holds reads
`.failed(EnvironmentError.gone)`.

Outside SwiftUI, a model or a view controller keeps an operation's data
alive by holding the `Retention` that `handle.retain()` returns, and lets it
go with itself; the policy it attached with stays with the retention, so a
`storeOnly` holder is never fetched for behind its back. `revalidate()` on
the environment refetches what is stale or failed when the app returns to
the foreground.

A store is filled from a payload as well as from the network.
`try await environment.commitPayload(CharacterQuery(id: "1"), fixture)` runs
the operation's plan over bytes in a response's shape and commits them as a
fetch's response is, so a preview draws from a fixture and a test seeds its
store without a transport; the payload may carry part of what the operation
selects. For the paths that do go through the network, `BatonTesting`'s
`RecordedTransport` answers requests from recorded responses.

In this repository:

- `swift run RickAndMorty` opens the read-only sample, which keeps its store
  on disk.
- `GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage` opens the one with
  writes, connections, unions and a 1,800-definition schema.
- `swift test` runs the proofs.
- `swift run -c release BatonBenchmarks` prints the numbers behind
  [`BENCHMARKS.md`](BENCHMARKS.md).

Requires the 26 releases of Apple's platforms and Swift 6.2 tools. In a
checkout, `scripts/build-compiler.sh` builds the compiler from `compiler/`
and the plugin runs that one; a checkout that SwiftPM evaluated before the
compiler was built keeps its first answer until told
`BATON_COMPILER=local`. A package that depends on Baton downloads the
compiler bundle its release published; releases before the first that
publishes one need the checkout's.

## Caton

[Caton](https://github.com/shergin/caton) is the demo app: a macOS menu bar
inbox for GitHub notifications, built to show this framework in a real
product. It joins each notification to the live state of its pull request
or issue, and the number in the menu bar is the number of things waiting
on you.

## The name

In a relay, the baton is the thing that is actually handed over. Here it is
the data a screen hands each view: exactly what the view asked for, nothing
else. In Russian the same word, батон, is a loaf of bread, which is why the
symbol is 🥖 and the logo is a loaf.

## Compared with the other native clients

Baton is faster than Apollo iOS.

| | Baton | Apollo iOS 2.4 | Faster |
|---|---|---|---|
| Into the store | 3.4 ms | 318 ms | **94×** |
| Same payload again | 165 µs | 3.99 ms | **24×** |
| One field | 26 ns | 296 ns | **11×** |

The head-to-head is the Rick and Morty page, 686 KB and 899 records, on an
Apple M1 Pro, 2 October 2026. Before that field read, Apollo spends 228 ms
rebuilding the query into models. The run is in
[`BENCHMARKS.md`](BENCHMARKS.md). Baton 0.6.0, remeasured on the same
machine without re-running Apollo, is 4.1 ms into the store, under 200 µs
for the unchanged payload, and 28 ns a field. The shape is the same.
Apollo's response for the same data is 849 KB, because its normalizer asks
for `__typename` on every object. A launch with the file already open reads
the fixture back in 1.78 ms.

Apollo spends the difference building a model of the operation, once from
the response and again from the store. The write into the store itself is
the same speed, 1.2 ms and 1.4 ms in that head-to-head. Baton keeps the
record, the UI framework observes it, and the first body already has the
cached data. A changed field re-renders the view that read it.

The Kotlin runtime is not built yet, so the race above is Swift. Apollo
Kotlin uses the same model-and-store design and publishes its own cache
bench, a different query on a 2017 Galaxy S8 with JSON parsing excluded:
about 800 ms to write and 530 ms to read 6,000 records from memory. That
is the model-tree cost on their machine. A head-to-head waits on the
Kotlin runtime.

Apollo iOS and Apollo Kotlin are the two maintained native clients, and
they share that design. Each generates a model shaped like the operation,
keeps a string-keyed record store behind it, and re-executes the whole
query when any field that query read changes. A view cannot read that
store on the frame it appears: Apollo iOS's read is `async`, and Apollo
Kotlin's is documented to stay off the main thread.

| | Baton 0.6 | Apollo iOS 2.4 | Apollo Kotlin 5.2 |
|---|---|---|---|
| The GraphQL | In the view, beside the body | A `.graphql` file, and you write the screen query | A `.graphql` file, merged across the module |
| A child view receives | A lens: the fields it declared | A snapshot of the parent's dictionary | A nested model the parent can also read |
| Warm cache, first frame | The data | Loading. The read is `async` | Loading. The read stays off the main thread |
| One field changes | The view that read it | The whole query, rebuilt into a new tree | The whole query, rebuilt into a new tree |
| Bytes into the store | 4.1 ms | 318 ms | Rebuilds models into records. About 800 ms on their bench |
| Read it back | 28 ns a field, 0.54 µs a field in a view body | 228 ms to rebuild, then 296 ns a field | Rebuilds the operation into models. About 530 ms on their bench |
| Memory while scrolling | Plateaus. 42 pages stay near +5 MB | Keeps every record. No eviction | You call GC. TTL and trimming exist |
| A list | Pages merged in the store, one update per page | One watcher per page, concatenated in the pager | Pages merged in the store |
| An optimistic write | A typed response, rebased, 0.4 ms for the cycle | A separate mutable model you write into the cache | Opt-in. Watchers then re-run the query |
| The UI binding | `@Fragment` and `@Query` | None. The tutorial copies into a view model | Experimental Compose helpers, last released 2024 |
| On disk | System SQLite, one binary row a record | SQLite, one JSON string per record | Binary SQLite, with memory in front |

The longer comparison, with the approaches, the smaller Swift clients, the
sources and the places Apollo is ahead, is
[`docs/comparison.md`](docs/comparison.md).

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE),
at your option.
