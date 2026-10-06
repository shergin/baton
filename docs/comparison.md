# Comparison

Baton is the Relay shape on the platforms whose UI frameworks can see which
view read which field. Apollo iOS and Apollo Kotlin are the two maintained
native GraphQL clients, and they share a different shape: a generated model
per operation, a string-keyed record store behind it, and a watcher that
re-executes the whole query when any field that query read changes. The
smaller Swift clients that tried the Relay shape are unmaintained. The
companies with the hardest performance problems built the client in-house.

This page is the argument for choosing. The measurements Baton publishes are
in [BENCHMARKS.md](../BENCHMARKS.md), with the machine, the OS and the date.
Numbers below that are not in that file are someone else's, and they say so.
Versions are current as of October 2026: Baton 0.6.0, Apollo iOS 2.4.0
(20 August 2026), Apollo Kotlin 5.2.0 (16 September 2026) with normalized
cache 1.0.9.

## At a glance

| | Baton 0.6 | Apollo iOS 2.4 | Apollo Kotlin 5.2 | Relay (web) |
|---|---|---|---|---|
| Where the GraphQL lives | In the Swift file, beside the view | `.graphql` files | `.graphql` files | In the component, in a tagged template |
| The screen's operation | The compiler aggregates the fragments | You write the query and spread fragments into it | You write the query; the Gradle plugin merges every document in the module | The compiler aggregates the fragments |
| What a child receives | A lens over the record. Fields it did not declare have no accessor | A struct over the parent's dictionary, so the parent sees the child's fields too | A nested model class. The parent can read through it | An opaque fragment reference. The child reads it with `useFragment` |
| A warm cache, first frame | The data. The read is synchronous on the main actor | Loading. Every store read is `async` | Loading. Store calls are documented to stay off the main thread, and the Compose helper starts at `null` | The snapshot, when the query is already in the store or was preloaded. Otherwise Suspense |
| A changed field | The views that read it. Twenty observed rows and one changed field invalidate that row | The whole query, rebuilt into a new model tree, with no equality check | The whole query, rebuilt into a new model tree | The fragments whose seen records overlap the change. Unchanged snapshots are suppressed. Field granularity is a flag, off by default |
| Response into the store | 3.4 ms for 686 KB, 899 records | 318 ms for the same data | Models are normalized into records. Their bench: ~800 ms to write ~6,000 records, JSON excluded | A publish into a flat record map. No published store bench |
| Read it back | A slot load, 26 ns. Inside a body, ~0.5 µs | 228 ms to rebuild the query, then 296 ns a field | ~530 ms to rebuild ~6,000 records from memory, their bench | A re-read of the fragment snapshot |
| Memory | A release buffer. Forty-two pages plateau near +5 MB | Every record stays. Eviction has been the most-upvoted open issue since 2017 | A GC call you schedule, plus TTL and trimming | Retained operations, release buffer of 10, a sweep from each root |
| Lists | `@connection`. Pages merge into one list. One notification per page | A separate package. One query watcher per page, concatenated for display | `@connection` in the new cache. Pages merge | `@connection`. Pages merge. Edge directives edit the list |
| Optimistic write | A typed response, ingested like a server payload, rebased under later commits. The cycle is 0.4 ms | `perform` takes no optimistic response. A local-cache-mutation model can write the store by hand | Opt-in, off by default. Watchers are notified and re-run | An overlay the publish queue rebases onto every server payload |
| Identity | `Type:` and the values of the fields `baton.json` names, `id` unless configured; a path otherwise | `@typePolicy`, field policies, or a function | Compiler-configured keys, with a typename scope | `id` by default, the field name configurable; a path otherwise |
| Field errors | Stored on the record. `@required`, `@catch`, `@throwOnFieldError` | Travel with the response | Stored, and a partial cache read can return them | Stored on the record. The same directives |
| On disk | System SQLite, one binary row a record. The check reads it when memory misses. Optimistic layers stay in memory | SQLite, one JSON string per record, no memory layer in front | Binary SQLite, a memory cache chained in front, with TTL and a trim | Not the runtime's job |
| SwiftUI / Compose | `@Fragment`, `@Query`, `@Mutation` | None. The tutorial copies the result into a view model | Experimental helpers, last released July 2024. A colocation prototype is one commit from September 2025 | React hooks |
| Floor | The 26 releases, Swift 6.2 | iOS 15 | Current Kotlin, and Kotlin Multiplatform | A JavaScript toolchain |

## The numbers

Same operation, same graph, same machine. The fixture is the recorded Rick
and Morty page in `spec/rickandmorty/characters-page-1.json`: 686,254 bytes,
about 6,500 JSON objects, 899 records. Apollo's own query text for that
operation adds `__typename` to every object, so its response is 849,101
bytes. Both clients key entities by `id` and both produce 899 records.
Apple M1 Pro, macOS 26, release builds, 2 October 2026. Apollo's run is the
in-memory cache, not SQLite.

| Step | Baton | Apollo iOS 2.4 |
|---|---|---|
| Response bytes to normalized records | 2.14 ms | 317 ms, models and records together |
| Publish into an empty store | 1.24 ms | 1.39 ms |
| Bytes to data in the store | 3.4 ms | 318 ms |
| The same payload again, nothing changed | 165 µs, and no view | 3.99 ms |
| From the store to something a view can read | 115 µs to check availability. The lens then reads slots | 228 ms (`store.load` rebuilds the query into models) |
| One field | 26 ns, untracked | 296 ns, after that load |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../benchmarks/charts/apollo.svg">
  <source media="(prefers-color-scheme: light)" srcset="../benchmarks/charts/apollo-light.svg">
  <img alt="Baton and Apollo iOS 2.4, seconds, on a log axis" src="../benchmarks/charts/apollo.svg">
</picture>

The figure is that table, in seconds, on a log axis. Baton's store-to-data
mark is the availability check. The one-field mark is the untracked lens
read.

0.5.0 remeasured Baton on the same fixture and the same machine, and did not
re-run Apollo. Ingest 2.76 ms, commit into an empty store 1.35 ms, the same
payload again 187 µs, one field changed among 20 observed rows 376 µs, an
untracked read 29 ns, a tracked read inside a body 536 ns. That tracked read
is Observation's own cost: the spike measured 534 ns against 554 ns for an
`@Observable` property. The shape is unchanged: a 686 KB response is in the
store a few milliseconds after the bytes arrive, and a refetch that changes
one field invalidates one row.

What the time is spent on is the useful part. Apollo's publish into an empty
store is as fast as Baton's commit. The store is not where Apollo's time
goes. The 317 ms is the materialization, and it matches a report the
maintainers' tracker already had: about 6 ms of JSON deserialization against
about 159 ms of type mapping for an 874 KB response
([apollo-ios#3600](https://github.com/apollographql/apollo-ios/issues/3600),
2024). A later read pays the mapping again.

Apollo Kotlin's published bench is a different query on a different machine,
and it excludes JSON parsing. On a 2017 Galaxy S8, library 1.0.0-beta.1, a
nested query of about 6,000 records and 2 MB: about 800 ms to normalize the
generated models into the memory cache and about 530 ms to read them back
out into models. SQL is slower still, about 1.5 s to write and 830 ms to
read. A flat list of 10,000 records is the same order.
[Their table](https://www.apollographql.com/docs/kotlin/caching/performance).
It is not a ratio against the 3.4 ms. It is the same bill, itemized by the
people who pay it: the model tree is built on the way in and again on the
way out.

Three more of Baton's benches, same machine, from the 0.5.0 entry:

- Optimistic cycle on one renamed character, with the whole fixture
  committing underneath the layer: 413 µs. The row observes the change twice,
  when the layer appears and when a reverting restore lands. A payload that
  agrees with the layer notifies nothing.
- A connection page of 50 edges, transport recorded, ingest off the main
  actor, merge on it: 320 µs best. Forty-one pages, 2,100 nodes, 41
  notifications, one per page on the connection rather than one per row.
- Forty-two pages scrolled through a release buffer of ten. The pages share
  no records. The store stops growing at page ten, and the footprint since
  page one plateaus near +5 MB (+4.7 MB in the 0.5.0 run, between +4.2 and
  +5.0 across the runs). 0.6.0 remeasured those paths on a store without an
  image, and they did not move.

The image is the 0.6.0 entry, same machine, warm page cache. Hydrating 898
records into an empty store is 1.72 ms, against 1.37 ms to commit the same
records from a response, so the image's own share is about a third of a
millisecond. A launch in a new process has the fixture in the store 1.78 ms
after its handle asks when the file opened off the main actor, and 4.68 ms
when the main actor waited for the open. Keeping the image costs a commit
0.12 ms on the main actor and 1.16 ms off it. The file is 168 KB for the
686 KB response. It is a Mac, not a phone, and a warm page cache: flash
latency on a cold launch is not in these numbers.

The caveats on the head-to-head are in the benchmark file and they matter.
It is a Mac, not a phone. It is one fixture. Apollo is a release build with
default options and no SQLite, and Apollo's response is 24% larger because
of `__typename`. The comparison package is in the repository.

## Two approaches

### A model of the operation

Apollo's compiler emits a type for the selection. On iOS that type is a
struct with one stored property, a dictionary, and every accessor looks a
key up and casts. A named fragment is another struct over the same
dictionary, so passing it to a child passes a value with no identity, and
the parent's model exposes the fragment's fields unless an experimental
codegen option turns the merging off. On Kotlin the default shape gives the
fragment its own class, which is closer, and the parent still has a property
of that class, so the parent can read the child's fields. Neither is
masking. Masking is a child that cannot see what it did not declare, and a
parent that cannot see what the child declared.

The response becomes that model, and the model is then walked to produce
records keyed by strings. A read walks the records to produce a new model.
A watcher remembers the field keys the walk touched. On a write it
intersects that set with the changed keys and, on any overlap, does the walk
again. iOS calls the handler even when the new tree is equal. There is no
fragment watcher on either platform; both open requests date from 2022.

The UI layer, where it exists, sits outside that loop. Apollo iOS ships no
SwiftUI binding. The official tutorial holds the launches in a
`@Published` array on a hand-written view model. Apollo Kotlin's Compose
helpers collect a flow that starts at `null`, so the first composition takes
the loading branch when the data is already in memory, and the paging source
bypasses the normalized cache. The colocation the Kotlin lead argued for at
GraphQLConf 2025, `@Query` and `@Fragment` in the Kotlin file, is a prototype
repository of one commit.

This design has real advantages, and they are why it shipped and stuck. A
model is a plain value: loggable, previewable, passable into UIKit or a
composable that has never heard of the store. The cache is optional. The
schema does not have to be Relay's. Kotlin's new cache adds the pieces
native apps actually ask for: merged connection pages, TTL, partial reads,
garbage collection you can call, a binary SQLite row instead of a JSON blob.

The cost is structural. Tokenizing the JSON is the cheap part. Meta measured
a 20 KB response at 35 ms of parsing on Android in 2015, more than a frame,
and the decade since moved that cost into the objects built afterwards.
Apollo's own split, 6 ms against 159 ms, is that measurement repeated. A
view that wanted one field pays for every field of the operation, on the way
in and on the way out, and a change to one of them pays for it again.

### A lens over the record

Relay's compiler already separates the two walks. A normalization artifact
has every fragment inlined and writes a payload into a flat record map. A
reader artifact keeps the fragment boundaries, and at a spread it hands the
child a pointer instead of the child's fields. Baton keeps that split, runs
Relay's front end at a pinned revision behind its own driver, and emits a
Swift lens where Relay emits a reader.

The lens is a record reference, a context and one accessor per declared
field. Reading `character.name` loads a slot and registers the read with
Observation. A parent passes the lens, three references, and has no
accessor for the child's fields. Masking is the type. There is no snapshot to build, no
seen-record set to intersect, and no second copy of the data to keep equal
to the first.

The ingest writes those slots from the response bytes in one pass, off the
main actor. A commit on the main actor swaps the records that changed and
notifies the channels of the slots that changed. Each slot of a record is
its own channel, so a view wakes only for a field it read. The measured case
is the one that matters for a list:
twenty observed rows, one changed field, and that row is the one invalidated.
An equal value is not a change, so a refetch of an unchanged payload notifies
nothing: 187 µs at 0.5.0. The view's first body reads whatever the store
already has. Previous data stays on screen while a refetch is in flight.

Relay itself still builds the snapshot, because React cannot tell it which
component read which field. The re-read, the overlap test and the structural
recycling exist for that reason. SwiftUI's Observation and Compose's
snapshot state already record the read, so Baton's read side is the lens.
Relay's unit of invalidation is the fragment, with a field-level path behind
a flag that is off by default.

Two things follow for product code, and they are the point of the
stricter shape.

- The screen's query is not a file anyone maintains. Fragments live next to
  the views that read them; the compiler spreads them into one operation and
  rejects a field the schema does not have, at the character in the Swift
  file. One request per screen is the arrangement, not a review comment.
- The cache update is not a function anyone writes. Pagination is
  `@connection` on the fragment. An optimistic response is a value on the
  mutation. An insertion into a list is an edge directive. A field the view
  cannot do without is `@required`. The vocabulary is closed, short, and
  shared with a team that already runs Relay on the web.

The things this shape refuses are in the [vision](vision.md). No runtime
parser, no model layer beside the store, no policy object for identity or
for cache behavior.

### What the large apps did instead

Meta's native client, described by a Mobile GraphQL engineer in 2025 as
Relay-like and implemented in C++, generates typed accessors for the fields
a query selected and keeps the models immutable. Colocating a fragment with
the UI component was described as a longer-term goal, not the current state.
LinkedIn's 2016 pipelines on both platforms kept immutable models consistent
by id, and treated an unreadable cache entry as a miss so that a schema
change could not become a migration. Facebook's 2014 iOS rewrite left
fully normalized Core Data because it slowed with every added entity, and
the 2015 Android work moved off JSON-to-objects because the objects cost the
frame.

Those stacks split in two. One materializes an immutable tree per screen and
runs a consistency engine to patch the trees when an id changes. Reads of a
tree are then free, and updates cost work proportional to the trees that
mention the id. The other, Relay and Apollo, keeps normalized records and
rebuilds a tree per read. Writes are cheap and reads pay, which is the bill
in the tables above.

Baton keeps the normalized record as the only copy. A fragment's lens is the
immutable typed view Meta generates, pointed at a live slot.

## Pros and cons

### Baton

Pros:

- Cached data is in the first body. The read is a slot load on the main
  actor, 26 ns untracked, about half a microsecond inside a view.
- A 686 KB response is in the store in 3.4 ms, against 318 ms for Apollo iOS
  on the same fixture. An unchanged refetch is under 200 µs and updates no
  view.
- One changed field re-renders the view that read it. The bench with twenty
  observed rows invalidates that row, in 376 µs for the commit.
- Memory tracks the screens you are keeping. Forty-two pages that share no
  records, scrolled through a release buffer of ten, plateau near +5 MB.
  Pagination fetches leave the edges and the nodes; the page records are
  what gets collected, because the connection is what a root reaches.
- Optimistic data goes through the same ingest as a server response and
  rebases under later commits. The cycle is 0.4 ms, and a commit notifies
  only the slots whose visible value changed.
- A connection page merges into one list and notifies once, on the
  connection, rather than once per row already on screen.
- GraphQL lives next to the view. The child cannot read what it did not
  declare. The compiler, the directives and the words are Relay's, so a web
  team and a native team share one language.
- Generated code is one accessor per field. The fixture document at 0.1.0
  was 14.5 KB of Swift against 15.3 KB from Apollo iOS for the same
  operation. The sample's four screens were 27.8 KB, including the operation
  text and the plans. GitHub's schema, about 1,800 definitions, passes
  Relay's front end in 33 ms.
- Field errors survive in the store. `@required`, `@catch`,
  `@throwOnFieldError`, `@defer` and subscriptions over
  `graphql-transport-ws` are in 0.5.0, with benches for the error path.
- The store outlives the process. The image is one SQLite file through the
  system library, a binary row per record, written behind the commit.
  Optimistic layers are not written. A launch with the file already open
  has the fixture's 898 records in the store in 1.78 ms.

Cons:

- It is 0.6. The API breaks until 1.0. There is no Kotlin runtime yet.
  Android today means Apollo Kotlin.
- The image is narrower than Apollo Kotlin's cache. A row ages out after
  one launch that did not read it. The other bound is a size limit checked
  at launch, 64 MB unless told otherwise, not a trim of the largest
  records. The check reads the image on the main actor, and one process
  uses a file. A response that writes a record before the image is asked
  replaces the row and drops fields only the image held.
- The floor is the 26 releases of Apple's platforms. Apollo iOS still
  supports iOS 15.
- Identity is `id` unless `baton.json` names other fields for a type, a
  composite key among them, as Apollo configures key fields per type; a key
  is own scalar fields, so an entity keyed only through a link does not
  normalize yet.
- An operation is sent as its text, or, under Relay's `persistConfig`, as
  the id the build hashed and the registration file carries; never both,
  and no transport has a mode. The standard encoding writes `documentId`,
  after the GraphQL over HTTP working group's open proposal.
- Garbage collection runs on the main actor. Over about 9,000 records the
  pass is under a millisecond at best and a few milliseconds at the median.
- There is no install base, no IDE plugin and no language server. Apollo has
  a decade of production apps, a pager, an operation manifest and, on
  Kotlin, a cache viewer inside the IDE.

### Apollo iOS

Pros:

- It is the Swift client people already ship. Docs, GraphOS, a pagination
  package, automatic persisted queries, uploads, WebSockets and an
  experimental `@defer`.
- SQLite is in the box. The deployment floor is iOS 15.
- Cache keys are configurable, declaratively with `@typePolicy` and
  `@fieldPolicy` or with a function. That flexibility is load-bearing on
  schemas Baton cannot key yet.
- Publishing records is fast. On the shared fixture the in-memory publish is
  1.39 ms, level with Baton's commit. SQLite has shipped here for years,
  on the iOS 15 floor.

Cons:

- A view cannot read the cache in the frame it appears. The store has no
  synchronous read; each read hops through an actor and a new task.
- Watchers are per query. Any overlapping field re-executes the whole
  operation and delivers a new tree, equal or not. Fragment watching has
  four reactions in four years and no maintainer reply since July 2022.
- The generated model is a dictionary plus a cast. Turning field merging
  down is experimental, and leaving it on is how generated code escapes:
  users have reported a near-20 MB app-size increase and about 50,000 lines
  from a 16-line fragment change
  ([apollo-ios#2560](https://github.com/apollographql/apollo-ios/issues/2560)).
- Nothing collects the store. Eviction is the most-upvoted open issue, open
  since 2017 ([apollo-ios#142](https://github.com/apollographql/apollo-ios/issues/142)).
  The SQLite backend is one JSON string per record, with no memory layer,
  and the root record grows with every distinct root field. A production
  report on 2.1.2 measured a cold read of 4,922 records at 6 seconds, later
  more than 9, against 0.72 seconds from memory.
- The mutation API takes no optimistic response. Pagination keeps one
  watcher per page instead of a merged list. There is no data masking, no
  colocated GraphQL (the request has been open since 2020) and no SwiftUI
  layer.
- The codegen front end is a bundled GraphQL.js, so syntax the JavaScript
  reference implementation does not parse yet is syntax Apollo iOS cannot
  accept. The 3.0 plan is a cache rewrite led by one engineer. Its first
  phase is a row-per-field SQLite schema and per-field TTL. Object and field
  watchers are deferred to a second phase that has no estimate.

### Apollo Kotlin

Pros:

- The best disk cache in this comparison. Memory chained in front of a
  binary SQLite record, Relay-style `@connection` merges, TTL, partial
  reads that surface stored errors, and trimming.
- Optimistic updates exist, as an opt-in layer.
- Fragments generate their own classes. The compiler merges documents across
  modules, and the IDE plugin navigates between Kotlin and GraphQL.
- It is the multiplatform client: Android, and iOS through Kotlin. The 5.0
  line picked up fragment arguments, `@defer` and `@stream`, and `onError`.
- Two engineers ship it on a steady cadence. Majors land every two years or
  so, and the cache library went to 1.0 in March 2026.

Cons:

- The watcher is the same shape as on iOS. A set of field-key strings, an
  intersection, a full re-execution into a new model. Fragment watching is
  an open request from 2022.
- The published cost of that shape is about half a second to read 6,000
  records from memory and about 0.8 seconds to write them, on a 2017 phone,
  before JSON. A Netflix engineer profiling a scrolling feed in August 2026
  found watcher-key recomputation at about a third of cache CPU. The profile
  was one session on a debuggable emulator, by the author's own caveat, and
  the fixes landed as pull requests.
- A burst of changes can fill the watcher buffer and stall cache writes
  app-wide. LRU eviction can drop a record a live watcher still needs.
  Garbage collection does not run itself.
- Compose is not the product. The helpers are experimental, last released
  July 2024, and they render loading on the first composition. The
  colocated-fragment prototype has not moved since September 2025, and its
  author called the IDE support fragile. Generated `List` fields are
  unstable in Compose's sense, an issue open since March 2024.
- Data masking was requested once, in May 2025, and closed the next day on
  the grounds that the fragment is already a separate class. The parent can
  still read it.

### Relay, for a native app

Relay is the reference, and Baton is deliberately closer to it than to
either Apollo. The directives in a Baton file are Relay's:
`@argumentDefinitions`, `@refetchable`, `@connection`, `@appendEdge`,
`@prependEdge`, `@deleteEdge`, `@required`, `@catch`,
`@throwOnFieldError`, `@alias`, `@defer`. A team that already runs Relay on
the web does not learn a second client. They learn that the read is a
property instead of a hook.

Relay's own costs do not transfer, and they are not worth porting. The
snapshot, the overlap test and the recycling of unchanged subtrees exist
because React's render cannot report what it read. Suspension by throwing a
promise is a React mechanism. The release buffer, the optimistic rebase, the
connection handler and the normalization plan do transfer, and they are what
0.2 through 0.5 implemented.

Relay publishes no store benchmark, so there is no number to put next to
the 3.4 ms. Its read is a walk that builds a snapshot. Baton's read is the
slot.

## Other Swift clients

Apollo iOS is the only maintained general-purpose Swift client. The others
are a stopped port, a query builder, a codegen tool, a vendor SDK, or a
one-author store from 2026. Each one tried a piece of the same problem.
Standing below is the public repository in October 2026.

Two of them had the UI idea. [Relay.swift](https://github.com/relay-tools/Relay.swift)
put the fragment in the Swift file, masked it behind a pointer, and bound it
with `@Fragment`. Every store read decoded a struct, the release buffer was
fixed at zero, and the generator was a plugin for the JavaScript Relay
compiler. Relay 13 replaced that compiler in January 2022 and removed the
plugin API. The last commit had already landed the previous November.
[Graphaello](https://github.com/nerdsupremacist/Graphaello) went the other
way: `@GraphQL` on a SwiftUI property, and the tool wrote the fragment. The
runtime underneath was Apollo, and the last commit was June 2022.

[SwiftUIGraphQL](https://github.com/minm-inc/swiftui-graphql) is the later
SwiftUI binding. `@Query` sits on the view, a fragment generates a protocol,
and a cache keys objects by typename and id. The models are `Codable` trees,
the GraphQL stays in `.graphql` files, and the query's own struct conforms
to the fragment protocol, so the parent can still read those fields. The
repository was last pushed in January 2026.

Two 2026 projects rebuild the store and leave the view alone.
[cachebay-ios](https://github.com/lockvoid/cachebay-ios) reads synchronously
under a lock, watches fragments, merges `@connection` pages, layers
optimistic updates, and writes SQLite behind. Operations come from
`.graphql` files through its own CLI. It ships no property wrapper; a demo
app shows one way to drive SwiftUI from the callbacks.
[SwiftGraphQLClient](https://github.com/MarlonJD/SwiftGraphQLClient) is
Kindred's stack, published in May 2026: `Codable` models, a normalized
cache, record watchers as `AsyncStream`, optimistic layers, SQLite, uploads,
and subscriptions. No SwiftUI API. Both are one author. Neither publishes a
number this repository has rerun.

The rest do not keep a normalized store.
[swift-graphql](https://github.com/maticzav/swift-graphql) is a typed query
builder whose cache drops every stored query that mentions a changed type.
[swift-graphql-codegen](https://github.com/pm-dev/swift-graphql-codegen),
[Syrup](https://github.com/Shopify/syrup), and
[GQLSwift](https://github.com/BaherTamer/GQLSwift) generate models or
document strings and stop. swift-graphql-codegen's author is the person who
filed Apollo's field-merging report, the one where generation never
finished. [Artemis](https://github.com/Saelyria/Artemis),
[SociableWeaver](https://github.com/NicholasBellucci/SociableWeaver),
[TinyGraphQL](https://github.com/GetStream/TinyGraphQL),
[Gryphin](https://github.com/dbart01/Gryphin), and
[AutoGraph](https://github.com/autograph-hq/AutoGraph) build the query in
Swift and decode into a model you own.
[Servo](https://github.com/eliperkins/Servo) is a macro repository that
stops at its first commit. Chester, GraphQLicious, and LiveGQL are archived.
GraphQLSwift's GraphQL and Graphiti are servers.

The vendor SDKs are maintained, and each speaks one backend.
[Firebase Data Connect](https://github.com/firebase/data-connect-ios-sdk)
generates the client from a connector and exposes `@Observable` query
objects for the whole query, with an entity cache and SQLite.
[Mobile Buy SDK](https://github.com/Shopify/mobile-buy-sdk-ios) is the
Storefront API. [Amplify Swift](https://github.com/aws-amplify/amplify-swift)
speaks AppSync; DataStore is Gen 1 only, and Amplify's own guide off
DataStore points at Apollo iOS 1.x. The older
[AppSync SDK](https://github.com/awslabs/aws-mobile-appsync-sdk-ios) is an
archived Apollo fork, and
[aws-appsync-apollo-extensions-swift](https://github.com/aws-amplify/aws-appsync-apollo-extensions-swift)
adds auth and WebSockets to Apollo iOS 1.x.
[ApolloCombine](https://github.com/joel-perry/ApolloCombine) is Combine
publishers over Apollo 1.x.
[GraphQLAPIKit](https://github.com/futuredapp/GraphQLAPIKit) is one agency's
wrapper around Apollo iOS 2.0.4, and it says so in its limitations: no
Apollo cache. Calling
[Apollo Kotlin](https://github.com/apollographql/apollo-kotlin) from Swift
is the multiplatform route. The models arrive as Objective-C classes, and a
`Flow` needs a bridge such as SKIE. It fits a data layer that is already
Kotlin.

| | What you write | What a view holds | Store | SwiftUI | Standing |
|---|---|---|---|---|---|
| [Relay.swift](https://github.com/relay-tools/Relay.swift) | `graphql("""…""")` beside the view | A fragment pointer. The child reads its own fields | Normalized. Every read decodes. Release buffer fixed at zero | `@Query`, `@Fragment`, `@Mutation` | Last release May 2021. Last commit November 2021 |
| [Graphaello](https://github.com/nerdsupremacist/Graphaello) | `@GraphQL` on the view's properties. The tool writes the fragment | Generated types for that view | Apollo's | Property wrappers, with loading and error states | Last release December 2021. Last commit June 2022 |
| [SwiftUIGraphQL](https://github.com/minm-inc/swiftui-graphql) | `.graphql` files | A `Codable` tree. A fragment is a protocol the query's struct conforms to | Normalized on typename and `id`. `@Query` follows the query | `@Query` | Last push January 2026 |
| [cachebay-ios](https://github.com/lockvoid/cachebay-ios) | `.graphql` files, its own CLI | Generated types. `watchFragment` calls back | Normalized, synchronous reads, `@connection`, optimistic layers, SQLite | None in the library | One author, since April 2026 |
| [SwiftGraphQLClient](https://github.com/MarlonJD/SwiftGraphQLClient) | `.graphql` files, a SwiftPM plugin | `Codable` response models | Normalized, `AsyncStream` watchers, optimistic layers, SQLite | None | Kindred's stack, published May 2026, one author |
| [swift-graphql](https://github.com/maticzav/swift-graphql) | A schema-generated query builder | The decoded result | A document cache. A changed type drops every query that mentioned it | None. Combine | Last release May 2024. Status questions unanswered |
| [swift-graphql-codegen](https://github.com/pm-dev/swift-graphql-codegen) | `.graphql` files, a build plugin | `Codable` structs with stored properties | None. The app takes no runtime dependency | None | One author, active in 2026 |
| [AutoGraph](https://github.com/autograph-hq/AutoGraph) | A query builder, any `Decodable` | The model you wrote | None | None | Low activity through December 2025 |
| [Artemis](https://github.com/Saelyria/Artemis) | A result builder, `Partial<T>` | The partial you asked for | None | None | Last commit September 2022 |
| [SociableWeaver](https://github.com/NicholasBellucci/SociableWeaver) | A result builder that prints the query | Whatever decodes the response | None | None | Last release April 2022 |
| [TinyGraphQL](https://github.com/GetStream/TinyGraphQL) | A query builder | The response you decode | None | None | GetStream. Last release 2021. Later commits are CI |
| [Gryphin](https://github.com/dbart01/Gryphin) | A generated query DSL for one schema | Generated models | None | None | Dormant since 2019 |
| [GQLSwift](https://github.com/BaherTamer/GQLSwift) | A plugin that emits the document string | Nothing | None | None | One release, April 2026 |
| [Syrup](https://github.com/Shopify/syrup) | `.graphql` files, templates | Generated Swift models, and Kotlin | None. Codegen only | None | Shopify. 0.16.1 in March 2026 |
| [Servo](https://github.com/eliperkins/Servo) | A macro, marked in progress | Unfinished | Unfinished | Unfinished | First commit, January 2024. Nothing after |
| [Firebase Data Connect](https://github.com/firebase/data-connect-ios-sdk) | Operations declared for Firebase | Generated models | An entity cache and SQLite | `@Observable` refs, for the whole query | Firebase. Maintained |
| [Mobile Buy SDK](https://github.com/Shopify/mobile-buy-sdk-ios) | The Storefront API | The SDK's models | None | None | Shopify. Quarterly, with the API |
| [Amplify Swift](https://github.com/aws-amplify/amplify-swift) | AppSync operations | Amplify's models | DataStore, Gen 1 only | None for GraphQL | AWS. The DataStore guide migrates to Apollo iOS 1.x |
| [AppSync SDK](https://github.com/awslabs/aws-mobile-appsync-sdk-ios) | AppSync operations | An Apollo 0.x fork's models | That fork's cache | None | Archived |
| [AppSync extensions](https://github.com/aws-amplify/aws-appsync-apollo-extensions-swift) | Apollo iOS 1.x, plus AppSync auth | Apollo's models | Apollo's | None | Maintained, for Apollo 1.x |
| [ApolloCombine](https://github.com/joel-perry/ApolloCombine) | Apollo 1.x operations | Apollo's models | Apollo's | None | Last push March 2024 |
| [GraphQLAPIKit](https://github.com/futuredapp/GraphQLAPIKit) | Apollo iOS 2.0.4 | Apollo's models | None. The cache is listed as unsupported | None | One agency. 1.0.0 in January 2026 |
| [Apollo Kotlin, from Swift](https://github.com/apollographql/apollo-kotlin) | `.graphql` files in a Kotlin module | Objective-C classes. A `Flow` needs a bridge | Apollo Kotlin's | None | The route when the data layer is already Kotlin |

None of them is the combination at the top of this page. The client that
had colocated fragments, masking, a compiler-built operation, a normalized
store, and SwiftUI wrappers was Relay.swift, and it stopped when the
compiler it plugged into was replaced. Baton owns the binary, the source
scanner, and the emitter, and pins Relay's parser, schema, IR, and
transforms behind that driver.

Outside Swift, Apollo Client on React Native is the cross-platform exit.
Shopify moved its apps there. It has had opt-in masking since December 2024,
and it is a JavaScript runtime. Expedia's graphql-kotlin, Netflix's DGS
client, and Kobby generate JVM callers. Meta, Airbnb, and LinkedIn run
in-house clients. They are evidence about the shape, and they are not
packages. Nothing public in 2026 says Meta has open-sourced its native
client.

## Where the others are ahead

Disk policy, reach, and time in production.

Both Baton and Apollo Kotlin store binary rows in SQLite and answer from
memory before they touch the file. Kotlin is ahead of that: TTL, partial
reads, and a trim. Baton's image is the system's library, one file, written
behind the commit and read by the availability check when memory misses. A
row survives one launch that did not read it. The bound is that generation
plus a size limit checked at launch, 64 MB unless told otherwise. The check
reads the image on the main actor, and one process uses a file. On the
benchmark machine a launch with the file already open has 898 records in
the store in 1.78 ms. Apollo iOS's SQLite is one JSON string per record,
with no memory layer, and it is the option on the iOS 15 floor.

Apollo iOS runs on iOS 15 and has a pagination package, persisted-query
manifests and a tutorial-shaped path into an existing UIKit or SwiftUI app
that already thinks in view models. Baton requires the 26 releases and a
willingness to put the fragment in the view.

Identity configuration is theirs. `@typePolicy` and Kotlin's key configuration
cover entities whose key is not `id`, and field policies that answer a root
field from an argument. Baton keys on `id`.

Installed base is theirs. In public repositories, `apollo-ios` appears in
about 541 Swift lockfiles, against about 7,200 for Alamofire, and Apollo's
Kotlin artifacts in about 630 Android version catalogs, against about 38,000
for Retrofit. Private apps are missing from those counts. The point stands:
Apollo is the default, and Baton is a 0.6 with something to prove. The
head-to-head fixture is the proof on offer, and it is rerunnable.

## Sources

Baton's measurements: [BENCHMARKS.md](../BENCHMARKS.md), entries 0.1.0
through 0.6.0, recorded on an Apple M1 Pro. The Apollo iOS comparison is the
0.1.0 entry; the launch and hydration numbers are the 0.6.0 entry. The
commands that reproduce them are at the bottom of that file.

Apollo's own material: [Apollo iOS docs](https://www.apollographql.com/docs/ios),
[the 2.0 migration guide](https://www.apollographql.com/docs/ios/migrations/2.0),
[Apollo Kotlin cache performance](https://www.apollographql.com/docs/kotlin/caching/performance),
[the new normalized cache](https://www.apollographql.com/blog/the-new-apollo-kotlin-normalized-cache)
(9 March 2026),
[ApolloStore](https://www.apollographql.com/docs/kotlin/caching/store).
The Kotlin performance page states the Galaxy S8, the library version and
the exclusion of JSON parsing.

Issues and reports named above:
[apollo-ios#142](https://github.com/apollographql/apollo-ios/issues/142),
[apollo-ios#1328](https://github.com/apollographql/apollo-ios/issues/1328),
[apollo-ios#2329](https://github.com/apollographql/apollo-ios/issues/2329),
[apollo-ios#2560](https://github.com/apollographql/apollo-ios/issues/2560),
[apollo-ios#3556](https://github.com/apollographql/apollo-ios/issues/3556),
[apollo-ios#3600](https://github.com/apollographql/apollo-ios/issues/3600),
[apollo-kotlin#6525](https://github.com/apollographql/apollo-kotlin/issues/6525),
[apollo-kotlin-normalized-cache#136](https://github.com/apollographql/apollo-kotlin-normalized-cache/issues/136),
[apollo-kotlin-normalized-cache#385](https://github.com/apollographql/apollo-kotlin-normalized-cache/pull/385).
The 6-to-9-second cold read is a community report against Apollo iOS 2.1.2,
not a number from this repository.

The Swift clients in [Other Swift clients](#other-swift-clients) are taken
from their own repositories in October 2026. SwiftUIGraphQL's fragment
protocols and cache key are from its README. cachebay's synchronous reads,
fragment watches, and lack of a SwiftUI wrapper are from its docs.
SwiftGraphQLClient's cache, watchers, and `Codable` models are from its
README. Amplify's migration off DataStore names Apollo iOS 1.x in Amplify's
own guide.

Relay: [Thinking in Relay](https://relay.dev/docs/principles-and-architecture/thinking-in-relay/),
[the runtime architecture](https://relay.dev/docs/principles-and-architecture/runtime-architecture/),
[Relay 21](https://relay.dev/blog/2026/05/18/relay-21/).
Meta's native client is from the 2025 description by a Mobile GraphQL
engineer; its storage layout and its numbers are not public. LinkedIn's
pipelines are the 2016 engineering posts. Facebook's frame-budget numbers
are the 2014 and 2015 engineering posts linked from those discussions.
