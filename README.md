# Baton 🥖

**Status: 0.4.0.** Reads, writes and lists run through every layer, with
tests and benchmarks behind the claims: cached data in the first body, one
changed field re-rendering one row, memory bounded by a release buffer rather
than by how far the user scrolls, optimistic responses that show at once,
rebase under every commit and revert on failure, and connections that merge
their pages in the store and grow by one notification per page. The API will
break freely until 1.0.

Relay for SwiftUI and Compose. A view declares the GraphQL fragment it reads,
beside its body. The compiler aggregates the fragments of a screen into one
operation, validates everything against the schema at build time, and emits a
small typed lens per fragment. The runtime normalizes responses into records
that the UI framework itself observes, so a screen fetches once, renders
cached data in the first frame, and re-renders only the views whose fields
changed.

Baton is aligned with Relay, not Apollo: the same directives, the same
conventions, the same compiler lineage. A team running Relay on the web and
Baton on native speaks one language. Where Relay's design is React's rather
than GraphQL's (snapshots, re-reads, suspension by thrown promises), Baton
leaves it out: SwiftUI's Observation and Compose's snapshot state already know
which view read which field.

The design is in [`docs/vision.md`](docs/vision.md). Constraints it assumes
live in [`docs/principles/`](docs/principles/). The vocabulary is
[`docs/terminology.md`](docs/terminology.md).

## What it is, and will be

Shipped so far: the compiler over Relay's front end, lens types, the
observable store, the one-pass ingest, `@Fragment` and `@Query` for SwiftUI,
lookups, the Rick and Morty sample (0.1.0); retained roots, the release
buffer, collection, the four fetch policies, invalidation and expiration,
preload (0.2.0); `@Mutation` as an action value, optimistic layers, abstract
types, lookups by id across types, the GitHub sample (0.3.0); `@connection`
with merged pages and `loadNext`, `@refetchable`, fragment arguments,
`@alias(as:)`, the edge directives (0.4.0). Still to come, in order: errors
and `@defer`, persistence. The promises:

- **A fragment per view.** GraphQL lives in the Swift file, next to the view
  that reads it, as a full, valid document. A parent passes a child its
  fragment as a pointer-sized value; a child can read nothing it did not
  declare.
- **One request per screen.** The compiler assembles the operation from the
  fragments spread into it and emits a persisted id for it. Nobody writes the
  screen's query by hand, and nothing waterfalls.
- **Cached data in the first frame.** Reads are synchronous on the main
  actor; a handle resolves against the store before the first body runs.
  Decoding, normalization, persistence and garbage collection run off it.
- **Only changed views re-render.** Records are observable objects; a body
  that read `user.name` is invalidated when that field of that record changes
  and at no other time. A commit of a thousand records costs tens of
  microseconds on the main thread.
- **Honest data.** Nullability is what the schema says; `@required` and
  `@catch` work as in Relay; field errors survive caching; staleness is a
  phase a view can read.
- **Small everything.** Generated code is one line per field plus data
  tables. The runtime depends on Foundation and Observation. The compiler is
  one prebuilt binary, shared by the Swift and (later) Kotlin runtimes.

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

## Using it

Add the package and the plugin to a target, put `baton.json` with the schema
path (and lookups) at the package root, and build. The plugin runs `batonc`
for every Swift file that declares GraphQL and reports schema errors at the
GraphQL text. `swift run RickAndMorty` opens the read-only sample;
`GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage` opens the one with
writes, connections, unions and a 1,800-definition schema; `swift test` runs
the proofs;
`swift run -c release BatonBenchmarks` prints the numbers behind
[`BENCHMARKS.md`](BENCHMARKS.md).

Requires the 26 releases of Apple's platforms and Swift 6.2 tools. The
compiler binary is built from `compiler/` with `scripts/build-compiler.sh`
until artifact bundles are published.

## The name

In a relay, the baton is the thing that is actually handed over. Here it is
the data a screen hands each view: exactly what the view asked for, nothing
else. In Russian the same word, батон, is a loaf of bread, which is why the
symbol is 🥖; a proper logo will follow.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE),
at your option.
