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
  fragment as a pointer-sized value; a child can read nothing it did not
  declare.
- **One request per screen.** The compiler assembles the operation from the
  fragments spread into it and emits a persisted id for it. Nobody writes the
  screen's query by hand, and nothing waterfalls.
- **Cached data in the first frame.** Reads are synchronous on the main
  actor; a handle resolves against the store before the first body runs, and
  after a launch the store reads what that handle needs from its image on
  disk. Decoding, normalization, the image's writes and garbage collection
  run off it.
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

Still to come: tooling and the road to 1.0. Each release is described in
full in [`CHANGELOG.md`](CHANGELOG.md).

## Using it

Add the package and the plugin to a target, put `baton.json` with the schema
path (and lookups) in the target's directory or at the package root, and
build. The plugin runs `batonc` for every Swift file that declares GraphQL
and reports schema errors at the GraphQL text.

To keep the store across launches, give the environment an image:
`Environment(url: endpoint, persistence: Persistence(name: "Main"))`; call
`removeAll()` on it at sign-out.

In this repository:

- `swift run RickAndMorty` opens the read-only sample, which keeps its store
  on disk.
- `GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage` opens the one with
  writes, connections, unions and a 1,800-definition schema.
- `swift test` runs the proofs.
- `swift run -c release BatonBenchmarks` prints the numbers behind
  [`BENCHMARKS.md`](BENCHMARKS.md).

Requires the 26 releases of Apple's platforms and Swift 6.2 tools. The
compiler binary is built from `compiler/` with `scripts/build-compiler.sh`
until artifact bundles are published.

## The name

In a relay, the baton is the thing that is actually handed over. Here it is
the data a screen hands each view: exactly what the view asked for, nothing
else. In Russian the same word, батон, is a loaf of bread, which is why the
symbol is 🥖 and the logo is a loaf.

## Compared with the other native clients

Apollo iOS and Apollo Kotlin are the two maintained native GraphQL clients,
and they share one design. Each generates a model shaped like the operation,
keeps a string-keyed record store behind it, and re-executes the whole query
when any field that query read changes. A view cannot read that store on the
frame it appears: Apollo iOS's read is `async`, and Apollo Kotlin's is
documented to stay off the main thread. Baton generates a lens per fragment
and the UI framework observes the record: the first body already has the
cached data, and a changed field re-renders the view that read it.

The response and read rows are the head-to-head in
[`BENCHMARKS.md`](BENCHMARKS.md). Rick and Morty, page one: 686 KB, 899
records, Apple M1 Pro, October 2026. Apollo's response for the same data is
849 KB, because its normalizer asks for `__typename` on every object. The
memory and optimistic rows are Baton's 0.5.0 benches on that machine. The
disk row is 0.6.0. A launch with the file already open reads the fixture
back in 1.78 ms.

| | Baton 0.6 | Apollo iOS 2.4 | Apollo Kotlin 5.2 |
|---|---|---|---|
| The GraphQL | In the view, beside the body | A `.graphql` file, and you write the screen query | A `.graphql` file, merged across the module |
| A child view receives | A lens: the fields it declared | A snapshot of the parent's dictionary | A nested model the parent can also read |
| Warm cache, first frame | The data | Loading. The read is `async` | Loading. The read stays off the main thread |
| One field changes | The view that read it | The whole query, rebuilt into a new tree | The whole query, rebuilt into a new tree |
| Bytes into the store | 3.4 ms | 318 ms | Rebuilds models into records. Their own bench is below |
| Read it back | 26 ns a field | 228 ms to rebuild, then 296 ns a field | Rebuilds the operation into models |
| Memory while scrolling | Plateaus. 42 pages stay near +5 MB | Keeps every record. No eviction | You call GC. TTL and trimming exist |
| A list | Pages merged in the store, one update per page | One watcher per page, concatenated in the pager | Pages merged in the store |
| An optimistic write | A typed response, rebased, 0.4 ms for the cycle | A separate mutable model you write into the cache | Opt-in. Watchers then re-run the query |
| The UI binding | `@Fragment` and `@Query` | None. The tutorial copies into a view model | Experimental Compose helpers, last released 2024 |
| On disk | System SQLite, one binary row a record | SQLite, one JSON string per record | Binary SQLite, with memory in front |

Apollo Kotlin publishes its own cache bench, which is a different query on a
2017 Galaxy S8 and excludes JSON parsing: about 800 ms to write and 530 ms
to read 6,000 records from memory. The cost the two benches share is the
rebuild of the model tree.

The longer comparison, with the approaches, the smaller Swift clients, the
sources and the places Apollo is ahead, is
[`docs/comparison.md`](docs/comparison.md).

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE),
at your option.
