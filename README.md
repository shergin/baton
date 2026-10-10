<p align="center">
  <img src="baton.png" alt="A loaf of bread, drawn in one line: the Baton logo" width="160">
</p>

# Baton 🥖

**Baton brings Relay to SwiftUI and Compose.** A fragment beside every view,
one request per screen, cached data in the first frame, and a re-render only
where a field changed. New to GraphQL? [Why GraphQL](docs/why-graphql.md)
answers what mobile engineers ask first.

In Swift, UIKit and AppKit are supported too: a controller holds the same
handle a view does ([the recipe](docs/recipes/uikit.md)).

A view declares the GraphQL fragment it reads, beside its body. The compiler
aggregates the fragments of a screen into one operation, validates everything
against the schema at build time, and emits a small typed lens per fragment.
The runtime normalizes responses into records that the UI framework itself
observes.

Baton is aligned with Relay, not Apollo (but
[works great with an Apollo backend](#works-with-your-server)): the same
directives, the same conventions, the same compiler lineage. A team running
Relay on the web and Baton on native speaks one language. Where Relay's design is React's rather
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
The agent's first page is
[`docs/recipes/agents.md`](docs/recipes/agents.md): what to read, the
shape of a screen, what never to write, and a review checklist.

## By the numbers

Two head-to-heads against the maintained native clients, on the same
data: the Rick and Morty page, 686 KB and 899 records. Same machine, same
day, Apollo configured as its documentation says, both harnesses in this
repository. Every number is in [`BENCHMARKS.md`](BENCHMARKS.md) with the
device, the OS and the date.

**Swift against Apollo iOS 2.4**, Apple M1 Pro, 2 October 2026:

| | Baton | Apollo iOS | Faster |
|---|---|---|---|
| The response into the store | 3.4 ms | 318 ms | **94×** |
| The same payload again | 165 µs | 3.99 ms | **24×** |
| A screen whose data is already in the store | the first body has it, after a 115 µs check | 228 ms to rebuild the query | |

**Kotlin against Apollo Kotlin 5.2**, a Google Pixel 9 on Android 17,
release builds, 9 October 2026:

| | Baton | Apollo Kotlin | Faster |
|---|---|---|---|
| The response into the store | 5.3 ms | 44.7 ms | **8.4×** |
| The same payload again | 0.30 ms | 1.1 ms | **3.8×** |
| A screen whose data is already in the store | a 0.75 ms check | 25 ms to rebuild the query | **33×** |

The difference is the model tree Apollo builds from the bytes and rebuilds
on every read. Baton materializes nothing a view did not read: on the phone
the whole response is in the store in less than a 120 Hz frame, 1.0 ms of
it on the main thread, and the screen reads its fields from there. From
the last byte to a list a screen can render, Baton is 5.3 ms; Apollo
Kotlin is 44.7 ms with its default cache write before the response is
emitted, or about 12 ms to a first render with the write deferred and
32 ms of work after it.

Also measured: an optimistic write shows at once and the whole cycle costs
0.4 ms; forty-two pages of scrolling plateau near five megabytes, since
the store releases what no view holds; a launch with the image already
open reads the page back in 1.78 ms before any request; on the JVM, the
Kotlin runtime ingests the same page in 1.1 ms.

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
  Kotlin runtimes.
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

SwiftUI on the left, from the sample. Compose on the right, from the Kotlin
sample: the same documents, the same lenses and the same phase, in
Kotlin's words. Both APIs will still move before 1.0.

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
                CharacterRow(
                    character: $0.characterRow
                )
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) {
                characters.retry()
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
    fragment CharacterRow_character on Character {
      name
      status
      image
    }
    """)
@Composable
fun CharacterRow(
    character: CharacterRow_character,
) {
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
    val query = rememberQuery(
        CharactersScreenQuery(page = page),
    )
    when (val phase = query.phase) {
        is Phase.Ready -> LazyColumn {
            val characters = phase.data.characters
            items(characters?.results.orEmpty()) {
                CharacterRow(it.characterRow)
            }
        }
        Phase.Loading ->
            CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) {
            query.retry()
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
    @refetchable(
      queryName: "IssueListPaginationQuery"
    )
    @argumentDefinitions(
      count: {type: "Int", defaultValue: 20}
      cursor: {type: "String"}
    ) {
      issues(
        first: $count
        after: $cursor
        states: OPEN
      ) @connection(key: "IssueList_issues") {
        edges { node { id ...IssueRow_issue } }
      }
    }
    """)
    var repository: IssueList_repository

    var body: some View {
        let issues = repository.issues
        ForEach(issues.nodes) { issue in
            IssueRow(issue: issue.issueRow)
        }
        if issues.hasNext {
            ProgressView().task {
                try? await issues.loadNext()
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
    @refetchable(
      queryName: "IssueListPaginationQuery"
    )
    @argumentDefinitions(
      count: {type: "Int", defaultValue: 20}
      cursor: {type: "String"}
    ) {
      issues(
        first: $count
        after: $cursor
        states: OPEN
      ) @connection(key: "IssueList_issues") {
        edges { node { id ...IssueRow_issue } }
      }
    }
    """)
@Composable
fun IssueList(repository: IssueList_repository) {
    val issues = repository.issues
    LazyColumn {
        items(issues.nodes) {
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
that is quick to generate, easy to review, and hard to get silently wrong. What an agent reads first, and checks before
handing a change back, is
[`docs/recipes/agents.md`](docs/recipes/agents.md).

## Status

0.14.0 (Kalach). On Swift, reads, writes, lists, errors and persistence
run through every layer, with tests and benchmarks behind the claims: cached
data in the first body, one changed field re-rendering one row, optimistic
responses that show at once and revert on failure, connections that merge
their pages in the store, field errors read through Relay's directives,
deferred fragments, subscriptions, and a store that outlives the process.
The Kotlin runtime runs on the JVM and on Android, held to the same
compiler and the same fixtures under `spec/`: every case and every script
of the specification passes through code the compiler generates, with a
Compose for Desktop sample, an Android sample and a head-to-head against
Apollo Kotlin behind it. From 0.13.0 it is on Maven Central as
`com.shergin.baton:baton`, with a Gradle plugin, `com.shergin.baton`, that
runs the compiler ([the recipe](docs/recipes/gradle.md)). The API will
break freely until 1.0; each release is in [`CHANGELOG.md`](CHANGELOG.md).

## Works with your server

Baton asks nothing of the server beyond the GraphQL specification. A query
or mutation is a standard GraphQL-over-HTTP request, so Apollo Server,
Apollo Router, GraphQL Yoga, Hive Gateway, Hasura and any other
spec-compliant server answer it as they are, with no plugin or adapter.
Point the compiler at the schema, wherever it comes from, and build.
`@defer`, subscriptions and persisted operations follow each server's own
conventions, and a federated graph looks like any other server. The
server of fate's GraphQL template answers as it is, its posts connection,
`node(id:)` and mutations included; its live subscriptions arrive over
graphql-sse but carry a `JSON` scalar, so they update no record. A process
holds one schema family: two environments may share it, and two schemas
in one process must not give two types one name.

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

The two head-to-heads are under [By the numbers](#by-the-numbers): Swift
against Apollo iOS on an M1 Pro, Kotlin against Apollo Kotlin on a Pixel 9,
the same Rick and Morty page of 686 KB and 899 records each time. Baton
0.6.0, remeasured on the same Mac without re-running Apollo, is 4.1 ms into
the store, under 200 µs for the unchanged payload, and 28 ns a field; the
shape did not move. Apollo's response for the same data is 849 KB, because
its normalizer asks for `__typename` on every object.

Apollo spends the difference building a model of the operation, once from
the response and again from the store. The write into the store itself is
the same speed, 1.2 ms and 1.4 ms in that head-to-head. Baton keeps the
record, the UI framework observes it, and the first body already has the
cached data. A changed field re-renders the view that read it.

Apollo Kotlin is far quicker than Apollo iOS on the same data, and its
cache merge is within twice Baton's commit: the store is not where its
time goes. The time goes to building the model tree from the bytes and
normalizing it, 30 of its 44.7 ms on the Pixel 9, and to rebuilding that
tree on every read, 25 ms there. Once the tree exists, a field is a
property load, 2 ns against Baton's 47 ns lens read; a screen that reads
every field of twenty rows pays Baton about 7.5 µs after a 0.75 ms check.
Apollo Kotlin also keys the eleven locations whose `id` is null as one
record, so it holds 889 records where Baton holds 899.

Apollo iOS and Apollo Kotlin are the two maintained native clients, and
they share that design. Each generates a model shaped like the operation,
keeps a string-keyed record store behind it, and re-executes the whole
query when any field that query read changes. A view cannot read that
store on the frame it appears: Apollo iOS's read is `async`, and Apollo
Kotlin's is documented to stay off the main thread.

| | Baton | Apollo iOS 2.4 | Apollo Kotlin 5.2 |
|---|---|---|---|
| The GraphQL | In the view, beside the body | A `.graphql` file, and you write the screen query | A `.graphql` file, merged across the module |
| A child view receives | A lens: the fields it declared | A snapshot of the parent's dictionary | A nested model the parent can also read |
| Warm cache, first frame | The data | Loading. The read is `async` | Loading. The read stays off the main thread |
| One field changes | The view that read it | The whole query, rebuilt into a new tree | The whole query, rebuilt into a new tree |
| Bytes into the store | 4.1 ms on an M1 Pro (Swift); 5.3 ms on a Pixel 9 (Kotlin) | 318 ms | 44.7 ms on the same Pixel 9; 8.8 ms on the JVM |
| Read it back | 28 ns a field, 0.54 µs a field in a view body (Swift); 47 ns a field (Kotlin, Pixel 9) | 228 ms to rebuild, then 296 ns a field | 25 ms to rebuild on the Pixel 9, then 2 ns a field |
| Memory while scrolling | Plateaus. 42 pages stay near +5 MB | Keeps every record. No eviction | You call GC. TTL and trimming exist |
| A list | Pages merged in the store, one update per page | One watcher per page, concatenated in the pager | Pages merged in the store |
| An optimistic write | A typed response, rebased, 0.4 ms for the cycle | A separate mutable model you write into the cache | Opt-in. Watchers then re-run the query |
| The UI binding | `@Fragment` and `@Query`, in SwiftUI and in Compose | None. The tutorial copies into a view model | Experimental Compose helpers, last released 2024 |
| On disk | System SQLite, one binary row a record | SQLite, one JSON string per record | Binary SQLite, with memory in front |

The longer comparison, with the approaches, the smaller Swift clients, the
sources and the places Apollo is ahead, is
[`docs/comparison.md`](docs/comparison.md).

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE),
at your option.
