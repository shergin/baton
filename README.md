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

**Try it on your app.** The quickest way to know what Baton does for your
app is to ask your coding agent to integrate it on a branch, measure the
screens that matter before and after, and report back. Whatever stands in
the way, a blocker, a missing feature or a number that disappoints, belongs
in an [issue](https://github.com/shergin/baton/issues). It is your chance to
make the app faster and its GraphQL much more pleasant to work with, and to
shape Baton while it is young.

## What it is, and will be

- **A fragment per view.** GraphQL lives in the Swift file, next to the view
  that reads it, as a full, valid document. A parent passes a child its
  fragment as a record reference and a context; a child can read nothing it
  did not declare.
- **One request per screen.** The compiler assembles the operation from the
  fragments spread into it and, under Relay's `persistConfig`, the id a
  server registers it under. Nobody writes the screen's query by hand, and
  nothing waterfalls.
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

SwiftUI on the left, from the sample. Compose on the right, as the Kotlin
runtime is designed: the same documents, the same lenses and the same phase,
in Kotlin's words. The Kotlin runtime is being built, and both APIs will
still move before 1.0.

A fragment beside the view that renders it, and one query for the screen:

<table>
<tr><th>SwiftUI</th><th>Compose</th></tr>
<tr valign="top">
<td>
<sub>

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
            List(data.characters?.results ?? []) {
                CharacterRow(character: $0.characterRow)
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { characters.retry() }
        }
    }
}
```

</sub>
</td>
<td>
<sub>

```kotlin
@Fragment($$"""
    fragment CharacterRow_character on Character {
      name
      status
      image
    }
    """)
@Composable
fun CharacterRow(character: CharacterRow_character) {
    Row {
        Avatar(url = character.image)
        Text(character.name ?: "Unknown")
        Text(character.status ?: "")
    }
}

@Query($$"""
    query CharactersScreenQuery($page: Int) {
      characters(page: $page) {
        results { id ...CharacterRow_character }
      }
    }
    """)
@Composable
fun CharactersScreen(page: Int) {
    val characters = rememberQuery(
        CharactersScreenQuery(page = page),
    )
    when (val phase = characters.phase) {
        is Phase.Ready -> LazyColumn {
            val results = phase.data.characters?.results
                .orEmpty()
            items(results, key = { it.recordID }) {
                CharacterRow(it.characterRow)
            }
        }
        Phase.Loading -> CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) {
            characters.retry()
        }
    }
}
```

</sub>
</td>
</tr>
</table>

A list is a Relay connection. The fragment owns the pagination, the store
owns the merged pages, and the view reads them like any other field:

<table>
<tr><th>SwiftUI</th><th>Compose</th></tr>
<tr valign="top">
<td>
<sub>

```swift
struct IssueList: View {
    @Fragment("""
        fragment IssueList_repository on Repository
        @refetchable(queryName: "IssueListPaginationQuery")
        @argumentDefinitions(
          count: {type: "Int", defaultValue: 20}
          cursor: {type: "String"}
        ) {
          issues(
            first: $count, after: $cursor, states: OPEN
          ) @connection(key: "IssueList_issues") {
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
            ProgressView().task {
                try? await repository.issues.loadNext()
            }
        }
    }
}
```

</sub>
</td>
<td>
<sub>

```kotlin
@Fragment($$"""
    fragment IssueList_repository on Repository
    @refetchable(queryName: "IssueListPaginationQuery")
    @argumentDefinitions(
      count: {type: "Int", defaultValue: 20}
      cursor: {type: "String"}
    ) {
      issues(
        first: $count, after: $cursor, states: OPEN
      ) @connection(key: "IssueList_issues") {
        edges { node { id ...IssueRow_issue } }
      }
    }
    """)
@Composable
fun IssueList(repository: IssueList_repository) {
    val issues = repository.issues
    LazyColumn {
        items(issues.nodes, key = { it.recordID }) {
            IssueRow(it.issueRow)
        }
        if (issues.hasNext) item {
            CircularProgressIndicator()
            LaunchedEffect(issues) {
                runCatching { issues.loadNext() }
            }
        }
    }
}
```

</sub>
</td>
</tr>
</table>

A Kotlin document is a `$$"""…"""` string, since `$` starts a template in a
plain one and GraphQL's variables need it. The view marker stands on the
composable, and the composable remembers the operation value it shows.

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
- **0.8.0 (Back Straight).** The spine: the fetch and the stream as values
  beside the phase, one door for every write, the store owning roots, ages
  and the collector, an environment that ends, a session's keys in its
  store; enums, input objects, mapped scalars and configured identity; one
  transport verb; the image evicting by launch.
- **0.9.0 (Krendel).** The ground before Kotlin: the runtime contract under
  `spec/` and scripts as the second kind of fixture, the verdict on the
  root with the phase derived from it, a payload at the door, an
  operation's resolution in place of a placeholder environment, lenses
  equatable by anchor, `@inline` built, and a compiler whose plan carries
  facts and whose `decide` stage spells nothing, for a second emitter.

Still to come: the road to 1.0. Each release is described in full in
[`CHANGELOG.md`](CHANGELOG.md).

## Works with your server

Baton asks nothing of the server beyond the GraphQL specification. A query
or mutation is a standard GraphQL-over-HTTP request, so Apollo Server,
Apollo Router, GraphQL Yoga, Hive Gateway, Hasura and any other
spec-compliant server answer it as they are, with no plugin or adapter.
Point the compiler at the schema, wherever it comes from, and build.
`@defer`, subscriptions and persisted operations follow each server's own
conventions, and a federated graph looks like any other server.

Baton strives to support each backend's own features wherever they fit the
design and make sense for a client. If yours does something Baton does not
speak yet, open an issue.

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
