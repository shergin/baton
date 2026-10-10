# Changelog

Notable changes, written so a person can read them. Pre-1.0, breaking changes
are expected and listed without apology.

## Unreleased

- An image's open no longer holds a read of a file it is making.
  `Persistence` notes at construction whether its file exists; until the
  writer's first open, a read of a file that did not answers from memory
  alone, since the file holds nothing yet, while a file that did is
  waited for, or opened by the read, as before, so a warm start's first
  frame still has the list. On the Pixel 9 the sample's cold start with an
  empty store slept 23 ms of its first composition behind the file's
  creation, written through to flash; its first frame now comes 26 ms
  sooner, level with the Apollo Kotlin twin's, and the list 24 ms sooner,
  255 ms from the launch against the twin's 327 (`BENCHMARKS.md`,
  9 October).
- A response is read where it is parsed. The Kotlin environment awaits the
  transport's payload on the ingest dispatcher and the Swift environment on
  a concurrent task, so the store's thread is entered once, for the commit,
  rather than first when the bytes arrive: a response that lands while the
  main thread draws a frame is parsed before the frame ends, not after it.
  On the Pixel 9 the sample's first page, 686 KB, is parsed and normalized
  in about 5 ms of a worker's time, inside the cold start's first frame.
- The Kotlin twin of the exchange, `kotlin/samples/exchange`: an `Exchange`
  over `baton.Transport` in common Kotlin, the wrapper a production
  endpoint needs and the library does not ship. Credentials are the base
  transport's, read per attempt; a 401 is replayed once after
  `challenged()`; a query or a subscription refused with a 5xx or by a lost
  connection is sent again with a doubling, jittered wait, as many times as
  `attempts` allows and never past `deadline`; a mutation is never sent
  twice; a stream that delivered is not sent again. The Kotlin GitHub
  sample sends through it, as the Swift one sends through
  `examples/Exchange`, and `docs/recipes/exchange.md` has its Kotlin half,
  quoting the compiled loop. `ExchangeTests` in the runtime's JVM tests
  prove it over `baton-testing`'s doubles and a loopback server: the
  replayed challenge carries the renewed token, a second challenge fails,
  a 503 then a 200 is sent twice, the attempts bound the sends, a deadline
  that expires during the backoff fails at once, a mutation refused with a
  503 is sent once, a cancelled consumer ends the held attempt, an
  environment over an exchange reads ready after a retry, and a held
  mutation's optimistic layer stands through a retry beside it.
- The Android sample tells the environment the process's lifecycle:
  `Activation` in `kotlin/samples/android` observes `ProcessLifecycleOwner`,
  sets `isActive` false when the last activity stops and true when the
  first starts, and calls `revalidate()` on the return; the view model
  closes it before the environment ends. `docs/recipes/views.md` quotes it
  as the Kotlin half of the lifecycle section of `docs/recipes/uikit.md`,
  which now links it.
- Kotlin's `TransportError` carries the connection's own failure as its
  `cause` when there was no response: `HttpTransport`, `OkHttpTransport`
  and the socket clients pass the exception they caught, so a wrapper can
  tell a connection that was lost or timed out, which a retry may mend,
  from a request the transport could not make, which would repeat. A
  status 0 with no cause is still the latter.
- A Baton app is a client of the server of fate's GraphQL template as it
  ships: responses recorded from it under `spec/fate/` prove its posts
  connection, `node(id:)`, `postAdd` with `@prependNode` and the
  graphql-sse stream of `fateLiveNode`, whose `JSON` payload lands at the
  subscription root and updates no record.
- The Kotlin runtime runs `spec/relay/` and `spec/fate/` as the Swift
  runtime does, so a fixture under either directory now holds both
  runtimes, as `docs/principles/two-runtimes-one-compiler.md` asks.
  `jvmRelayTest` compiles `spec/relay/sources` with `spec/relay/baton.json`
  through the Gradle plugin, which now names the Kotlin package, and runs
  every case and script but the unsupported ones under the same statuses as
  `BatonRelayTests`: the responses committed as payloads into a bare store,
  the dump compared with Relay's, a `check` step's answer compared, and each
  `reads` row read by walking the generated lens, with `throws` and
  `result` rows lifted as the Swift target's generated reads lift them; a
  case with a status runs as a known issue that fails once it passes.
  `jvmFateTest` proves the fate recordings through the Kotlin host
  `FateDocuments.kt`, the twin of `FateDocuments.swift`. Each harness runs
  in a JVM of its own, since the registry numbers types by name per process
  and Relay's test schema and fate's both declare a `User`. CI runs both.
- `docs/comparison.md` is current at 0.14: the at-a-glance table carries
  the Kotlin runtime's numbers on the Pixel 9 beside the Swift runtime's on
  the Mac, the Apollo Kotlin head-to-head is a table of its own, the cons
  say what the Kotlin runtime is and is not rather than that there is none,
  the image con no longer names a row the writer replaced, which 0.8.0
  fixed, and identity says what `baton.json` configures. `kotlin/README.md`
  says `baton-testing` builds for Android, as it has since 0.14.0.
- `docs/recipes/agents.md`, the page a coding agent reads first when it
  integrates Baton into an app: the reading order, the shape of a screen
  in Swift and Kotlin, what never to write, the compiler's diagnostics and
  what to run, and a review checklist. The README links it from "Try it
  on your app" and "Written by people, or by models".
- `docs/why-graphql.md`, for iOS and Android engineers who build on REST:
  the plumbing a REST screen needs, what GraphQL removes of it, what only
  Relay's fragments and store remove, what Baton adds, what stays the
  app's, and what it costs. The README's first paragraph links it.

## 0.14.0 (Kalach) — 2026-10-09

- The report `batonc generate --report` writes, `Baton.report.json` under
  the build plugin, lists each operation's and fragment's lens: every
  accessor's name, the response key it reads, and its shape, whether it
  reads absent, a `@catch` result, a throwing read or a list, with the lens
  it nests. A renamed accessor or a field that starts throwing now shows in
  the report's diff.
- The UIKit half of `docs/recipes/uikit.md`, compiled: a
  `UIViewController` over a handle, a `UITableViewController` whose cells
  bind a lens, and the app's lifecycle on the application's background and
  foreground notifications, beside the AppKit ones in the `Controllers`
  target. What both show is computed once, in `Content.swift`, and CI builds
  the target for the iOS Simulator. The README says that UIKit and AppKit
  are supported in Swift.
- `docs/recipes/uikit.md` quotes compiled code: the `Controllers` target
  under `examples/Controllers`, an `NSViewController` over a handle, a
  table whose cells bind a lens, and the app's lifecycle told to the
  environment, proven by `ControllersTests`. The recipe's controller
  observed `handle.phase` alone and read the fields in the loop's body,
  which renders the first response and never a later change to a field;
  the closure now computes what the controller shows, and the first frame
  is read synchronously rather than one suspension later. A controller's
  operations live in a `.graphql` file, since `@Query` is a view's storage.
- `spec/relay/`: Relay v21.0.1's `RelayResponseNormalizer-test.js`,
  `DataChecker-test.js` and its four reader suites (`RelayReader`,
  `RequiredFields`, `CatchFields`, `RelayErrorHandling`) harvested into
  cases, translated into Baton's keys by `scripts/relay-harvest/` and run
  by the Swift test target `BatonRelayTests`. A hand-seeded store becomes
  the response it stands for, kept only when Relay answers the same from
  it; a reader test's answer becomes `reads` rows read through the lenses
  the compiler reports, with `throws` and `result` rows for
  `@required(action: THROW)`, `@throwOnFieldError` and `@catch`. Relay's
  tests are measured against, not obeyed: of 227, 47 agree with Relay and
  must pass; 19 carry a status (`possible-bug`, `unspecified-behaviour`,
  `invalid-input`, `by-design`) and run with their results ignored until
  they pass; 51 use features Baton does not have and are kept out of the
  runs; 110 are not expressible yet, most of them a fragment read or
  checked at a record. `docs/decisions/relays-tests-are-measured-not-obeyed.md`
  is the record.
- The compiler refuses `OptimisticResponse` as the name of a Kotlin
  fragment or operation, with a message at the name, as it refuses `Data`:
  the builder a mutation nests hid a mutation of that name inside its own
  body, and the Kotlin written for it did not compile. An enum or an input
  object of the name takes the suffix the package's kept names take. The
  Swift emitter accepts the name, as before.

- The Gradle recipe names Google's Maven repository beside Maven Central
  for dependencies, where the runtime's AndroidX pieces come from: a
  consumer built from the recipe alone could not resolve the Compose
  runtime. Its snippets apply the Kotlin plugin, include `.graphql`
  documents among the hosts, and say where `baton.json`'s entries are
  defined.

- The Android ingest benchmark measures what a store holds with the
  change set out of the measuring frame, which had kept it alive: the
  figures 0.13.0's notes give for a store after the commit, 1,100, 896 and
  884 KB, were the store and the change set together; a store holds 328 KB
  (`BENCHMARKS.md`). The benchmark app is profileable from the shell, so
  `simpleperf` can record it on a device.

- The change set finds an entity a response names again by the bytes of
  its key field, through a table in front of its string index, so the
  record's key is built once per record and not once per occurrence; the
  fixture names 6,533 entities for 899 records. A profile of the Kotlin
  ingest on the Pixel 9 put the decoding, the concatenation and the
  hashing of those keys at a fifth of its time. The Pixel 9 ingest takes
  4.3 ms where it took 5.2, allocating 250 KB less, and the response is in
  the store in 5.3 ms against Apollo Kotlin's 44.7; on an M1 Pro the Swift
  ingest takes 1.73 ms where it took 2.06 (`BENCHMARKS.md`).

- `docs/runtimes.md` maps the two runtimes' files to the vocabulary, a
  file per concept, and both trees now match it: the Swift runtime gained
  `Availability.swift`, `Resolution.swift`, `Handle.swift` and
  `Subscription.swift` out of the files that held them, the Kotlin one
  `Connections.kt` and `Membership.kt`; moves, no logic. The boundary
  script checks the map and reads the Kotlin tree as it reads the Swift
  one: the common source set imports no platform, the testing module
  reaches the public surface alone, and every name generated Kotlin may
  spell is declared in the runtime. CI runs the Kotlin hostile-name sweep,
  over a `kotlinc` Gradle writes from the embedded compiler.

- Subscriptions on Android, through `baton-okhttp`: the Kotlin socket
  transport's `graphql-transport-ws` is the runtime's, in common code over
  a `WebSocketClient` the platform or an edge supplies, the JVM's own
  `JdkWebSocketClient` over `java.net.http` or `OkHttpWebSocketClient` over
  an app's OkHttp client, which Android has no socket without;
  `GraphQLTransportWebSocket(url, client = OkHttpWebSocketClient(okHttp))`.
  The same module brings `OkHttpTransport`, HTTP over the app's OkHttp
  client with its interceptors and pool, reading a response as the
  built-in transport does; the pieces a transport over any client needs,
  `Request.accept`, `requestErrors` and `answersInGraphQLResponse`, are
  public beside the two parsers. `baton-testing` builds for Android too,
  and holds the `SocketServer` double a socket transport's tests run
  against.

- The availability check counts a scalar cell as present only when its
  value fits the field's kind, in both runtimes: a cell the image wrote
  under a schema that since gave the field another kind reads as absent,
  so the operation fetches and the response writes the cell again, where
  the check used to take the cell as present and the lens then read
  nothing from it. A schema change needs no new `version` on the
  persistence; the version is for what the app caches meaning something
  else under the same shape.


- The vocabulary and both READMEs say that a process holds one schema
  family: the registry numbers types and slots by name for the whole
  process, so two environments over one schema share them, and two
  schemas in one process must not give two types one name.

- The Kotlin environment sends the snapshot system's apply notifications
  after the runtime's own writes, once per burst, posted behind the burst
  on its main dispatcher, so a model over `snapshotFlow` sees a change
  without Compose UI's frame clock; `docs/recipes/views.md` is the page, a
  handle held by a view model and read as a flow of what the screen shows.

## 0.13.0 (Bublik) — 2026-10-09

- The Kotlin runtime on Maven Central: `com.shergin.baton:baton`,
  `baton-testing` and `baton-inspector`, Kotlin Multiplatform artifacts for
  the JVM and Android, versioned with the release; and the Gradle plugin
  `com.shergin.baton`, `kotlin/baton-gradle`, the command's contract spelled
  in Gradle: a `BatonGenerate` task that runs `batonc generate` with the
  hosts, the configuration and the files it names declared as inputs and
  the generated Kotlin and the report as outputs, over the compiler
  `BATON_COMPILER` names or the release's artifact bundle, fetched once into
  the Gradle user home and checked against the checksum the release stamps
  into `kotlin/release.properties`. The checkout's own modules generate
  through it. The release workflow publishes the artifacts and the plugin
  from the tag, and `docs/recipes/gradle.md` is the page.
- The Kotlin store's keys live in a table under a lock, changed in place,
  as the Swift store's do. The table was an immutable snapshot replaced by
  compare-and-set: every new text a session rendered copied the type's
  whole table and scanned it for a freed number first, quadratic in the
  texts a type renders, a search field's terms for one. The image's locks
  are the same `Lock` now, in `Threads.kt`.
- The Kotlin environment's suspending calls, `fetch`, `mutate`,
  `commitPayload` and `end`, run on its main dispatcher whatever thread
  calls them, as the Swift environment's run on the main actor; a call
  from `Dispatchers.IO` used to fail the store's thread check. The
  synchronous calls are still made on the store's thread.
- The Kotlin record's cells are plain values, and a slot has a channel,
  Compose snapshot state, only once something read it: a write to a slot
  nobody read is a store into an array, where before every written slot
  carried a state object and every write went through the snapshot
  system. A read in composition registers the channel as it registered
  the cell, and the notifications are the same, slot by slot, under the
  spec's scripts. On a Pixel 9 the commit of the 899-record fixture takes
  0.95 ms where it took 1.35 ms, allocates 448 KB where it allocated
  672 KB, and a store holds 896 KB where it held 1,100 KB; the ingest does
  not move. The availability check, which reads records the same way,
  takes 0.74 ms where it took 1.2 ms, and the untracked field read pays
  about 3 ns for the second array it loads, 47 ns where it was 43. Against
  Apollo Kotlin on the same phone the response is in the store in 6.3 ms
  against 44.6 ms (`BENCHMARKS.md`).
- A Kotlin record's array of values is sized by what the record holds: a
  commit reserves the highest slot its change set writes to the record,
  and a write past the end grows it. Before, every record allocated an
  array as long as the type's slot count in the whole process, every
  document's fields on the type, when it rendered a few of them. The
  benchmark's process holds one document, so there the commit allocates
  24 KB less and a store holds 12 KB less, for a time within 0.02 ms; the
  gain is for a process with many documents on a type.
- A Kotlin query's state in a composition is a `QueryState`: `rememberQuery`
  returns one, holding the operation value and the handle it resolved the
  value to, with the `phase`, `fetch`, `isRefreshing`, `isStale`, `retry()`
  and `refetch()` that read the handle; `rememberSubscription` returns the
  subscription's handle, or null outside every provider. An operation
  value carries nothing of the live side any more: `resolution` is gone
  from the generated classes, which are `@Immutable`, and `Resolution`
  from the runtime, so the value a composable passes is never written to,
  and a composable that gains or loses the provider, or passes another
  policy, resolves anew. The three derived failures, `FieldErrors`,
  `RequiredFieldError` and `MissingDataError`, are equal by what they hold,
  so a failed phase that did not change compares equal, and a handle makes
  its root's lens once. The Kotlin format is 2; code generated for format 1
  fails to compile against this runtime with a message to rebuild.
- A collection pass marks the records it reaches with the store's epoch, a
  number on the record, where it kept a set of them; the sweep reads the
  mark, and a root prunes its links to swept records by the record's own
  flag, so a pass allocates nothing. On an M1 Pro the pass over one root
  reaching 50,004 records takes 4.7 ms where it took 6.4 ms
  (`BENCHMARKS.md`, which also records that the pass is 2.4 times what the
  keys step measured, a regression in the walk since found). The Kotlin
  collector marks the same way; it has no collection bench yet.
- A resolved variant is a reference. It had become a struct of ten lists
  on 6 October, looked up by value once per record by every walk, so each
  lookup retained and released ten buffers; a bisect of the benchmark
  suite found it. With it a class, the collection pass over 50,004 records
  takes 1.6 ms where it took 4.7 ms, the availability check 138 µs where it
  took 605 µs, hydration 1.9 ms where it took 2.4 ms, and the ingest a
  tenth less; the session's footprint is 8 MB smaller (`BENCHMARKS.md`).
- The ingest reads a matched field's members through the plan's list and
  never copies the field, which a profile found copying its lists once
  per JSON key; the record's value array and the store's table skip the
  dynamic exclusivity checks that main-actor isolation makes redundant,
  and the table is reserved for a change set's records before a commit
  grows it. On an M1 Pro the response is in a change set in 2.06 ms where
  it took 2.92, the commit into an empty store takes 470 µs where it took
  600, and an untracked lens read 21 ns where it took 26 (`BENCHMARKS.md`).

## 0.12.0 (Palianytsia) — 2026-10-08

- Baton and Apollo Kotlin end to end on a phone: `kotlin/samples/apollo-android`,
  the Android sample's twin over Apollo Kotlin 5.2.0 and its memory and SQL
  caches, and `kotlin/benchmarks/macro`, a Macrobenchmark module that drives
  both release builds against a fixed server in each app's process. On a
  Google Pixel 9, a cold start over the data on disk shows the list in
  240 ms, in the first frame, against Apollo's 272 ms after a spinner; a
  tap to a detail takes 22 ms against 33 ms; scrolling is the same in both.
  From the response's first byte to the list's frame Apollo is faster,
  42 ms against 58 ms. The Android sample's release build is signed with
  the debug key, its screens report their first draws, and a launch can
  ask for the fixed server.
- Apollo Kotlin measured beside Baton, `kotlin/benchmarks/apollo-comparison`:
  the same operation and graph through Apollo Kotlin 5.2.0 and its
  normalized cache 1.0.9, configured as documented, on the JVM and on a
  Google Pixel 9 in a release build. On the phone the response is in
  Baton's store in 6.5 ms and in Apollo's in 44.6 ms, and Apollo's read of
  the query back takes 25 ms where Baton's availability check takes 1.2 ms;
  a field of Apollo's read model costs 2 ns against 43 ns for a lens read.
  `docs/comparison.md` quotes these in place of Apollo's own bench.
- The Kotlin runtime's first numbers on a device, in `BENCHMARKS.md`: on a
  Google Pixel 9 running Android 17, the 899-record fixture tokenizes in
  19.0 ms off the main thread and commits in 6.7 ms on it, a debuggable
  device-test build, and in 5.1 ms and 1.3 ms from a release build that is
  not debuggable, `kotlin/benchmarks/android`, the medians of 300 runs;
  the native-runtimes record carries the number as the ingest budget's
  first evidence.
- The desktop sample keeps its page bar through a failure, so a page the
  public API refused (HTTP 429, Cloudflare's 1015 under a burst) can be
  left or retried; caches avatars for the process; keys its rows by
  `recordID`; keeps the store's image under the schema's digest, so a
  relaunch shows the characters before the network answers; and draws its
  screens to PNG files without a window through
  `gradle :samples:desktop:screenshot`.
- A second Kotlin sample, `kotlin/samples/github`, the Compose for Desktop
  twin of `examples/GitHubTriage`: sign-in with a token kept in memory, a
  repository with a star toggle whose optimistic response flips the star and
  the count, its open issues as a connection that loads the next page at
  the list's end, an issue whose composer appends an optimistic comment by
  the viewer through `@appendEdge`, and sign-out that ends the environment
  and removes the image. Its tests run the screens over `ScriptedTransport`.
- A Kotlin operation's companion is a `QueryType`, `MutationType` or
  `SubscriptionType` naming the operation's class beside its data, so
  `val rename = rememberMutation(RenameMutation)` infers its action's type.
  `OperationType` and the three are application API, outside the
  `baton.Generated` opt-in that an app's call to `rememberMutation` failed
  before; what generated code alone calls on them stays inside it.
- `@Fragment`, `@Query`, `@Mutation` and `@Subscription` repeat in Kotlin,
  so one composable can host several documents, as a button that stars and
  unstars hosts two mutations.
- The Kotlin `Retention` is `Hold` (`handle.retain(): Hold`,
  `hold.release()`), since `baton.Retention` hid
  `kotlin.annotation.Retention` from every file that writes
  `import baton.*`. Swift keeps `Retention`.
- `Phase`, `Fetch` and `MutationAction` are `@Stable` in Kotlin, so a
  composable handed a failed phase skips like any other. The Compose
  compiler's reports, turned on with `-PcomposeReports=true`, show every
  generated lens and `LensList` stable and every composable of the desktop
  sample restartable and skippable.
- `baton-inspector`, the Kotlin store inspector: `StoreInspector(environment)`,
  a live, searchable Compose view of the store's records by type with their
  fields, values and field errors, and `StoreExport.text(store)`, the dump.
  The desktop sample shows it in a third pane from its View menu
  (Command-I), and follows the system's light or dark appearance.
- The Kotlin runtime builds for Android (API 23 and up): the image on the
  system's SQLite through `AndroidSQLiteDriver`, `HttpTransport` and
  `Environment(url)` shared with the JVM, and
  `Persistence.named(name, directory = cacheDir.path)`, since the runtime
  holds no `Context`. `baton-inspector` builds for Android too; the
  desktop sample's screens moved to `kotlin/samples/shared`, which
  `kotlin/samples/android`, a phone app, shows as well; and
  `IngestBenchmark`, a device test, logs the Fixture's ingest and commit
  medians with the device's model for the ingest budget.

## 0.11.0 (Karavai) — 2026-10-07

- `rules_baton`, a Bazel module under `bazel/`, versioned with Baton: a
  toolchain its extension fetches from the release's artifact bundle,
  selecting the variant for the execution platform, or from the compiler
  `BATON_COMPILER` names; `baton_generate`, the command with every input
  and output declared, one output per source named as the SwiftPM plugin
  names it, whose files a `swift_library` or a `kt_jvm_library` lists in
  its `srcs`, with the report and the persisted documents file as output
  groups; and `baton_check_test`, `--check` over committed output.
  `docs/recipes/bazel.md` is its page, in place of the `genrule` on the
  command's contract page, and
  `docs/decisions/a-build-integration-holds-no-logic.md` records why a
  shell holds no logic and wraps no library rule. Answers issue 40.
- `batonc generate --persisted <file>` names where the persisted documents
  file is written, as `--shared` and `--report` name theirs, so a build
  system that declares its outputs before it reads `baton.json` can declare
  this one; without it the file goes under `--out`, else beside the
  configuration, as before. The contract page now also says that `--schema`
  beside `--config` overrides the configuration's schema, and that any
  source an `--emit` names gets a header-only output when it holds no
  GraphQL, both of which the compiler already did.
- The compiler's artifact bundle carries a static Linux binary for `x86_64`
  and one for `aarch64` beside the universal macOS one, listed under the
  gnu triples a Linux host reports and built with the musl target, so one
  binary runs on any distribution. SwiftPM on a Linux host and a Linux CI
  runner take the compiler from the same bundle a Mac downloads; the
  release workflow builds each on a host of its architecture, and CI builds
  and runs them so a release is never their first build. The Linux half of
  issue 40.
- A subscription's stream that fails on its environment, as one with no
  subscription transport does, ends with that failure as a request error
  ends it, in both runtimes, instead of retrying on the backoff forever;
  `retry()` opens it again. A transport failure still reconnects on the
  backoff.
- The Kotlin host's marker is recorded in
  `docs/decisions/the-kotlin-host-marks-a-document-on-the-composable.md`:
  a document is an annotation on the composable that renders, holds or
  acts, written in a `$$` raw string since `$` is a template in Kotlin and
  a variable in GraphQL; answers issue 6.
- `batonc` writes Kotlin lenses: a `@Stable` class per fragment and per
  operation's `Data`, equal by its anchor, with a property per field over
  the anchor's readers and a companion of its checks; an `@inline`
  fragment as a data class read once; a connection's state, `loadNext`
  and `refetch`. A mutation gets its `OptimisticResponse` and a
  `suspend operator fun invoke` on its `MutationAction`. A generated enum's
  case for an undeclared value is `Undeclared`, since `Unknown` and a
  schema value `UNKNOWN` are one class file on a file system that ignores
  case. The Kotlin runtime's tests now run every case of the manifest,
  its records and its reads, through the code `batonc` generates from
  `spec/sources`.
- The Kotlin runtime has its environment: the wire's `Request` and
  standard encoding, a `Transport` whose one verb returns a `Flow`, the
  handle with its fetch policies, its derived `Phase` and its `Fetch`,
  roots with retention, ages, the verdict and collection, the
  availability check, the heal, `mutate`, `commitPayload`, `end()` and
  the value-free log; `baton-testing` holds the scripted, recorded and
  silent transports. Every script of the manifest runs through it, to the
  steps that wait for the image, the subscriptions and the optimistic
  layers. A Kotlin operation's companion forwards its `Data`'s
  `fieldErrors` and `missingRequiredField`, so the handle judges its data.
- The Kotlin target refuses, with an error at the name, a field named
  `Variable` or `Variables`, and a fragment or an operation named like
  what the generated Kotlin calls or declares where it names the class
  (`Unit`, `OptIn`, `JvmName`, `listOf`, `anchor`, `equals`, `fieldErrors`,
  `name`, `text`, `data`, `Data`, `invoke` among them), for which it wrote
  Kotlin that did not compile; it writes `suspend`, `out` and `dynamic` in
  backticks. A corpus of Kotlin's hostile names,
  `compiler/src/tests/hosts/HostileKotlinDocuments.kt`, holds every
  keyword and every name the generated Kotlin declares in every position
  inside a document, and `scripts/hostile-name-sweep-kotlin.py` compiles
  the names of fragments and operations with `kotlinc`.
- The Kotlin runtime applies an optimistic response as a layer that a
  commit rebases under, the server's answer replaces and a failure
  reverts, notifying only what differs at the batch's end; holds a
  subscription's stream in a `SubscriptionHandle` that reconnects by the
  fixed backoff and parks while the environment is inactive; and loads a
  connection's pages and refetches a fragment. `Store` is public, and
  `Environment(transport, subscriptions, store)` takes it, with a `debug`
  flag that prints missing data until a log is set. Every script but the
  image's `relaunch` runs whole, and every case's `override` reads under
  its layer.
- The Kotlin runtime keeps the store's image: `Persistence(path)` or
  `Persistence.named(name)`, handed to `Store(persistence)`, writes every
  server batch behind the commit on a thread of its own, and the
  availability check reads back what memory lacks, so a relaunch draws
  its first screen from the last launch's data and ages survive it. The
  schema, the versions, the eviction by launch, the names forgotten with
  their rows and what never reaches the file are the Swift runtime's; the
  file is reached through the AndroidX SQLite driver API, with the bundled
  engine on the JVM alone. All twelve scripts run whole.
- The Kotlin runtime speaks to a server and to Compose. `HttpTransport`
  posts over `HttpURLConnection`, reading a deferred response's
  `multipart/mixed` parts and a subscription's `graphql-sse` events
  through the common `MultipartParser` and `EventStreamParser`, credentials
  per attempt, a request error answered as
  `application/graphql-response+json` as its `GraphQLErrors`;
  `GraphQLTransportWebSocket` speaks `graphql-transport-ws` over the JVM's
  `java.net.http.WebSocket`, one connection per transport; and
  `Environment(url)` makes an environment over HTTP. `LocalBaton`,
  `rememberQuery`, `rememberMutation` and `rememberSubscription` resolve
  operation values in a composition, retained while the composable stays.
  `kotlin/samples/desktop` is a Compose for Desktop app over the Rick and
  Morty API.
- Generated Kotlin compiles for two shapes it did not: a fragment or a
  field named like a plan's selection, `selection0`, which a lens read as
  the selection, since the selections are now members of a private object
  beside the operation's class, `` `HeroQuery-plan` ``, that no lens sees;
  and an `@inline` fragment's value of some two hundred linked fields,
  whose constructor passed the 64 KiB the JVM allows a method, since the
  constructor now reads each field through a private function of the
  value's companion, `` `read-name` ``.

## 0.10.0 (Vatrushka) — 2026-10-07

- The macros accept swift-syntax from 602 to 604, where they accepted 602
  alone, so an app that pins swift-syntax to its compiler's release, 603
  for Swift 6.3 or 604 for 6.4, resolves Baton, and gets swift-syntax's
  prebuilt macro support with it. The range spans the floor's toolchain to
  the newest release and CI builds both ends; recorded in
  `docs/decisions/swift-syntax-spans-the-floor-to-the-newest.md`.
- A list of scalars follows its element type in what it accepts, as the
  contract says and the Kotlin readers do: a list of strings reads a
  number's or a boolean's text, a list of floats reads an int, a list of
  ints reads a whole float, as the single-value readers always did. Before,
  a list element of another kind was dropped or read as nil where the
  scalar reader converted it.
- The Kotlin runtime has its store and its ingest: a response's bytes
  become a change set by the plan, with no JSON tree between, and the
  commit writes it into records whose cells are Compose snapshot state, so
  a read in composition registers the field and a write tells its readers
  alone. Connections merge, edge directives edit, errors land on their
  fields and deferred parts on their records, and every case of
  `spec/manifest.json` leaves its dump byte for byte on the JVM. The
  lenses, layers, retention and the image follow.
- `batonc` writes Kotlin: `generate --language kotlin`, or a `.kt` host,
  writes each operation as a class of its variables, equal by them, whose
  companion holds its document and plan, and the shared `Baton.baton.kt`
  with `Types`, `Slots`, the schema's enums and its input objects, in the
  package `baton.json` names under `"kotlin": {"package": …}` or the host's
  own. The `.kt` scanner reads every Kotlin string form, and a document with
  a variable is written in a `$$` string. A mapped scalar names its Kotlin
  type and converter under `kotlin`. Lenses follow with the Kotlin readers.
- The Kotlin runtime reads: the anchor's readers behind every accessor
  generated code prints, the owner that settles a lens's keys, conditions
  and `@arguments` once, and the placeholder behind a non-null link with no
  record. A read registers the one cell it reads; a missing or wrong-kind
  value is reported to the store's log once and reads as null or a zero
  value; `@required`, `@catch`, `@throwOnFieldError` and `@defer` read by
  Relay's rules, `@catch` as a `kotlin.Result`. Lenses written by hand
  after the Swift goldens read the `reads` rows of ten operations' cases
  as the cases say. Pagination and refetch come with the environment.
- `URLSessionTransport` reads a request error answered with a 4xx or 5xx
  status as `application/graphql-response+json`, as GraphQL Yoga, Hive
  Gateway and Apollo Router do for a document that fails to parse or
  validate or an unknown persisted document: it throws the server's
  `GraphQLErrors`, the request kind of failure, where it threw a
  `TransportError` with the body as text. A query fails with the server's
  errors and their `extensions`, and a subscription refused so ends rather
  than reconnecting by backoff. Another body outside 2xx, and any
  `application/json` one, is still a `TransportError`.
- The common-first record is amended: the JVM, through Compose for
  Desktop, is the first actual and the development target of the Kotlin
  runtime; Android is the first shipped target and the ingest budget's
  home. It names the two primitives a target supplies beside the image,
  the transports and the activity signal: a thread's identity and a
  double's shortest text.
- The authors' documents are under `spec/sources/`, one `.graphql` file
  each, with the configuration they compile with in `spec/tests/baton.json`,
  so a second runtime's harness compiles its lenses from the specification
  alone. The compiler's tests check them against the Swift test target's
  markers and prove they plan what the markers plan. The manifest is format
  3: `sources` names the directory and the configuration.
- The spec's scripts compare the requests a step sends: a `sent`
  expectation lists each request's operation and the exact body the
  standard encoding writes. Script `transport` holds the body's member
  order, the text without client fields and client directives, an enum and
  a mapped scalar sent as their text, and an input object's unset fields
  left out.
- A nullable variable left unset is left out of the request, and one the
  operation declares with a default is sent as that default, where both
  were sent as `null`; GraphQL applies an argument's default only to an
  absent variable, so the server and the store's keys now see one value.

## 0.9.0 (Krendel) — 2026-10-07

- `Payload`, bytes in a response's shape, is what the door takes:
  `commitPayload` takes a `Payload` where it took `Data`, and
  `mutate(_:optimistic:)` and a mutation's action take one where they took a
  `Variable`; a mutation's `OptimisticResponse` builder renders its
  `payload`, and the JSON value it collected its fields in is generated
  code's alone. `Variable` is a variable's JSON value and nothing else.
  Format 18. Recorded in
  `docs/decisions/a-payload-is-bytes-in-a-responses-shape.md`.
- A key the store holds at two slots, a rendering and the constant the
  build named for it afterwards, is one field in every report: a commit's
  `changed` count counts the pair once, and the store's dump and the
  inspector list the key once, and a record a batch creates counts among
  nothing changed whether or not the store holds twins. Before, a late
  constant doubled the count, made created records count, and showed the
  key twice in the dump, so a count or a dump compared across test runs
  differed by what else the process had touched.
- A handle stores no phase. The root, which is the store's, holds whether
  the store has the operation's data and the verdict on it, what the data
  deserves by `@throwOnFieldError` and a bubbling `@required`, settled by
  the store at the end of a batch that changed a null, a link, an error or
  a deletion, and when the handle finds or fetches the data; the handle's
  `phase` is derived from the root and its own `fetch` when it is read.
  The settling chain from the store through the environment to every
  retained handle is gone, and with it the store's last covert pointer to
  its environment. With data the phase reads the verdict and not the
  fetch, so a body that reads the phase is not woken by a fetch that
  changed nothing. Two readings change: a `storeOnly` handle that found no
  data reads ready once the operation's response is committed by any route
  or it is attached again over data the store now holds, and a handle that
  failed with nothing to show reads ready when it is attached again over
  such data; before, both stayed failed. Recorded in
  `docs/decisions/the-verdict-is-the-roots.md`.
- The compiler's `decide` stage spells nothing itself: it asks a naming the
  target supplies for every identifier, suffix, family and member name it
  needs, and the driver decides first and prints through the Swift target
  after; host files are found through a table of languages, with the Swift
  scanner and its checks behind it. The generated code does not change by
  a byte; the seams are those a Kotlin emitter needs.
- Scripts, the second kind of fixture under `spec/`: a file under
  `spec/scripts/` runs steps over time in one environment over one store,
  through a transport the steps answer, and after any step compares the
  dump, the reads, the fields notified, a handle's phase, fetch and
  stream, the check's answer, the records held and the log's events.
  Eleven scripts (`notifications`, `optimistic`, `connections`, `lifetime`,
  `ages`, `phase`, `check`, `heal`, `end`, `events`, `subscriptions`)
  hold the rules of the contract that no single commit could; the
  manifest goes to format 2, with `scripts` beside `cases`, and
  `spec/README.md` says what a script holds. The Swift runtime passes
  them all; loading a page through a lens and the transport's framings
  stay with the Swift tests for now.
- `customScalarTypes` takes, beside the Swift type as a string, an object
  by language, `{"swift": "Foundation.Decimal", "kotlin": "..."}`; a mapped
  scalar with no `swift` entry is an error at the configuration. The plan
  the compiler lowers carries the scalar's name and the `onError` value, no
  longer a Swift type or a Swift case: the Swift writer resolves both, so a
  second emitter reads the same plan. The refetch descriptor names the
  `@fetchable` field Relay's metadata names instead of a field spelled
  `id`. The generated Swift does not change by a byte.
- A view outside every `.environment(\.baton, ...)` reads
  `.failed(EnvironmentError.notInjected)` on its first body and makes no
  handle, and a mutation action in such a view throws the same; the shared
  placeholder environment, a real store that every view which forgot the
  injection fetched into, is gone. The absence of an environment is not a
  session. Format 17: an operation value's `resolution` is a `Resolution`,
  unresolved, resolved to its handle, or not injected.
- A lens is `Equatable`, by its anchor: the same record, the same scope and
  the same origin, by identity, as the principle always said. A row view
  whose stored state is a lens conforms in one line and opts into
  `.equatable()`, so a parent's re-render skips it.
- Five decisions recorded before the Kotlin lane, in `docs/decisions/`: the
  verdict is the root's and the phase is derived from it (superseding in
  part *The phase stays stored*; built behind a gate once the phase scripts
  exist); a payload is bytes in a response's shape, Relay's word, which the
  door and the optimistic builders will take in place of a `Variable`; a
  mapped scalar's host type is named per language under Relay's
  `customScalarTypes`, so the plan carries the scalar's name; the Kotlin
  runtime is common first with a platform as an actual (issue 24); and a
  format is per emitter.
- `spec/runtime.md`, the runtime contract: what a runtime does with a plan,
  a response and a store, in no language's terms, one paragraph a rule,
  each ending with the fixture that holds it or the word *unheld*, so a
  second runtime is held to the rules and not to the Swift that spells
  them. The principle *Two runtimes, one compiler* names it, and no longer
  counts the image's bytes among what the fixtures specify: a second store
  over the image reading the same records is what is shared.
- `@inline` is built: a fragment so marked compiles to a `Sendable`,
  `Hashable` struct of its fields in place of a lens, with a nested struct
  per link, an array per plural link and an initializer that takes the
  fields. The spread's accessor on the parent's lens builds the value from
  the record when it is called, on the main actor, through the readers a
  lens's accessors use, so what a read registers and reports is the same;
  a conditional or deferred spread yields an optional value and an aliased
  `@catch` around one a `Result`. An inline fragment spreads only inline
  fragments and takes no `@connection`, `@refetchable` or `@required`; a
  non-null mapped scalar in it reads optional, since a stored property
  cannot throw. A value's field errors include those of the values it
  spreads, so a catch or a policy around it sees them, and
  `@throwOnFieldError` on a value spread inside another value is refused.
  Format 16: generated code names the readers that build a plural link's
  values. A fragment spread by no operation is warned as one nothing can
  read, lens or value. Recorded in
  `docs/decisions/a-fragment-has-one-reading.md`.

## 0.8.0 (Back Straight) — 2026-10-06

The spine: the architecture the decision records describe, built. A
handle's fetch and a subscription's stream are values beside its phase,
and a failure says its kind; every write is a batch through one door; the
store owns the roots that keep records alive, stamps their ages at the
commit and collects from them alone; an environment ends; and the keys a
session renders are its store's. Around it, the shapes a production schema
has read as Swift types (enums, input objects, mapped scalars, configured
identity, client fields), the transport has one verb, the image evicts by
launch and keeps the rows a partial response did not name, and the
compiler validates, prints and reports what it compiled.

- The runtime reads a plural link out as values: `values`, `requiredValues`,
  `caughtValues` and `caughtRequiredValues` on an anchor build one value per
  linked record at the read, for the `@inline` fragment the compiler is
  learning to emit. `FieldErrors` and every `MappedScalar` are `Hashable`,
  so a value holding a caught field or a mapped scalar can be. A mapped
  scalar type of the app's own that was not `Hashable` must become it.
- A response with a few of a record's fields no longer empties the
  record's row in the image of the rest. The writer replaced every row with
  the commit's snapshot of the record, which for a record memory had not
  read from the image held only what this launch's responses wrote: a
  header fetched before a screen left the screen's next check a miss. The
  snapshot of a record memory has not read is now merged into its row, the
  response's cells over the row's; a record the check has read replaces
  its row as before, and so does a deleted one. Recorded in
  `docs/decisions/the-image-is-sqlite.md`.
- An image's `close()` is final. A commit or a read that reached a closed
  image opened its file again and took it back from the next environment's
  image, which then ran without one or, in a debug build, tripped the
  assertion that one image holds a file. A closed image drops what is
  queued after and misses every read; `removeAll()` still deletes the
  file. Recorded in `docs/decisions/an-image-belongs-to-one-store.md`.
- An operation's text is printed compact, with Relay's printer's own
  option: no newline, indentation or optional space, a comma between
  items, strings as they are. The test target's 115 operations hold
  61,797 bytes of text where they held 83,885, and the deepest realistic
  one 47% of what it held; the 65 KB operation of issue 36 that a server
  refused goes out at about half. Every persisted id changes with the
  text, so a team with registered ids regenerates the file and registers
  again; `batonc print` and `spec/documents` show the compact text.
  Recorded in `docs/decisions/operation-text-is-printed-compact.md`.
- A connection on the query root comes back from the image. The
  availability check hydrates the root a waited field at a time, and the
  connection's client link, Relay's handle key on the root, was never among
  them, so a reopened store read the connection as ready and empty while the
  same connection under a record came back whole; the check now reads the
  root's cell for the link before walking the connection. Issue 35.
- An operation's plan declares each distinct selection once, as a static
  member with its type stated, where it was one nested expression that
  copied a fragment at every spread. A union inside a union no longer
  exhausts the Swift compiler: the case of issue 34 that was killed at
  12 GB compiles in 1.7 s and 0.24 GB, and its plan holds 82 selections
  where it held 2,258. Recorded in
  `docs/decisions/a-plan-declares-each-selection-once.md`.
- An object under an interface or union takes its type from its
  `__typename` by a byte comparison with the names the plan lists, where
  the ingest made a string and took the registry's lock for every object;
  an escaped or unlisted name still asks the registry. A page of 899 union
  results ingests in 508 µs against 541, in `BENCHMARKS.md`.
- The compiler's tests fence the bytes of generated code per accessor line
  at 120 over the goldens, the budget 0.1.0 named and never enforced; the
  goldens stand at 106.1.
- A part of a deferred response that names a place no earlier part created,
  or a label the plan does not know, is logged as `partDropped` with its
  response path, where it was dropped without a word.
- An image over its size limit evicts instead of starting over: the rows
  of launches before the last go first, then the last launch's, and the
  file shrinks; only a file still over the limit with nothing left to evict
  starts again. Recency is the launch's, which the rows already record; no
  rule per type. Recorded in `docs/decisions/the-image-evicts-by-launch.md`.
- CI compares the benchmark suite's deterministic counts, the notifications
  a commit path fires and the events a commit logs, with
  `benchmarks/counts.txt`: `swift run -c release BatonBenchmarks --counts`
  prints them, one `count <name> <value>` a line, and a change to them is a
  diff to review where a timing would be noise.
- A recipe, `docs/recipes/discover-once.md`: a subject discovered once by
  its natural key and refreshed by id through `nodes(ids:)`, the pattern an
  app with external keys needs; the GitHub sample refreshes its rows that
  way from the toolbar.
- A recipe for derived state outside views, `docs/recipes/derived-state.md`:
  a model derives its value inside an `Observations` closure over the
  lenses it reads, and no commit signal is added; recorded in
  `docs/decisions/derived-state-is-observed-not-signaled.md`.
- `List.empty`, the value a view substitutes for a nullable list it reads
  as empty: `fragment.reviewRequests?.nodes ?? .empty`. A nullable list
  still reads as `List?`, since the server's null and its empty list
  differ.
- `Record`, `Value`, `Slot`, `TypeID`, `Owner` and `Members` are generated
  code's interface, behind `@_spi(Generated)`, now that no hook hands them
  out; an app's own files see lenses, handles, the environment, the log,
  transports and persistence.
- The GitHub sample keeps its store in an image across launches and signs
  out from the toolbar: the environment ends, the image's file is removed,
  and a new environment takes over, as the README describes.
- Two recipes: `docs/recipes/uikit.md`, a handle held by a view controller
  and rendered through `Observations`, with a cell over a lens; and
  `docs/recipes/porting-from-relay.md`, Relay's words beside Baton's, what
  differs on purpose, and what is not ported with its reason.
- A recipe for previews and tests, `docs/recipes/testing.md`: a fixture
  committed as a response, recorded responses, a held mutation and a driven
  subscription, the log in tests, and a bug report's dump as a fixture.
- `Environment.fetch` has one spelling, the operation value's. The one by
  type and variables, which returned the uncaught field errors as an array
  beside the other's throwing under `@throwOnFieldError`, is gone: a
  fetch's field errors are read where a view reads them, from the data,
  and each one no `@catch` handled is a `fieldError` event of the log.
- The environment logs. `Environment.log` is one closure called with each
  `LogEvent`, a value-free enum of names and counts: a fetch started,
  completed with its duration or failed with its failure's kind; a commit
  with its kind and the slots it changed in records that existed; a field error a fetch's response
  carried that no `@catch` handled, by operation and response path, as
  Relay's field logger reports them; the image opened, unavailable,
  written with its batches or failed; a field read and never fetched, a value
  a reader's type cannot hold, an id naming records of several types, a
  `@required(action: LOG)` field that is null, each by type and field. It
  replaces the four hooks, `reportMissing`, `reportUnexpected`,
  `reportAmbiguousIdentity` and `requiredFieldMissing`, which handed out
  records, slots and values. Debug builds print the missing-data cases
  until `log` is set.
- A query or subscription value's `resolution`, the handle a view resolved
  it to, is the mechanism's: declared behind `@_spi(Generated)` on the
  protocols and in generated code, read through `phase`, `fetch`,
  `isStale` and the rest as before.
- `Lens.typeName` is gone: a line of generated code per lens and a public
  requirement, read by nothing. Format 15.
- A fragment no operation reaches, directly or through another fragment,
  is a warning at its definition: nothing can read its lens, and the code
  generated for it is dead. The test target's fragments now all reach an
  operation.
- `batonc validate`, the same compilation with no output, for an editor or a
  hook; `batonc print <Name>`, one operation's text and id as the app sends
  them; and `batonc generate --check`, which writes nothing and names every
  output on disk that differs from what it would write, for a team that
  commits its generated code. The command's contract, with a Bazel
  `genrule` over it, is `docs/recipes/batonc.md`.
- `BatonInspector`, a third product of the package for a debug menu:
  `StoreInspector(environment)` is a view over the store, its counts, its
  records by type searchable by key, each record's slots with their values
  and field errors, and a share button that exports the store in the dump
  format `spec/` freezes, so a bug report can become a fixture. It reads
  and never writes.
- The compiler writes a report of what it compiled for a target:
  `batonc generate --report <file>`, and `Baton.report.json` in the build's
  output directory under the plugin. Every operation with its kind, source,
  id, variables, the fragments it reaches and its text; every fragment with
  its type, source, the operations that reach it and its printed
  definition; the schema's digest. Deterministic and by name, so a diff of
  two reports is the contract's change. The report and the persisted
  documents file sit beside the generated Swift in the plugin's output
  directory and are not outputs the build bundles, so neither reaches the
  app.
- A recipe, `docs/recipes/exchange.md`, and its sample, `examples/Exchange`,
  for what a production endpoint needs around the transport's one verb: one
  replay of an authorization challenge, a bounded retry with a jittered
  doubling backoff over a 5xx or a lost connection, a deadline across every
  attempt and its waits, and never a second send of a mutation or of a
  stream that delivered. The GitHub sample sends through it.
- `BatonTesting` gains `ScriptedTransport`, for an app's tests: answers
  from fixtures by operation name or through a responder, mutations held
  until the test replies or refuses, subscriptions driven by hand, and the
  requests sent listed by kind; and `wait(until:)`, which waits on the main
  actor for a handle or a store to settle.
- Subscriptions over HTTP, with `graphql-sse` in its distinct-connections
  mode: `URLSessionTransport` asks a subscription for `text/event-stream`
  and yields the payload of each `next` event until `complete`, so the
  environment's `subscriptions` may be the HTTP transport where a gateway
  holds no sockets. `EventStreamParser` splits the events beside
  `MultipartParser`'s parts, whatever the chunking. The single-connection
  mode waits for a gateway that cannot do HTTP/2.
- A subscription reconnects in its handle. A stream that ends by a failure
  while the handle is retained waits and opens again, by a fixed backoff: a
  step doubling from one second to thirty, jittered, reset by an event; the
  stream's value says `waiting(until:)` meanwhile, and `retry()` skips the
  wait; a request error, the server's refusal of the operation, ends the
  stream instead. The handle counts `resumptions`, the times the stream was opened
  again, so an owner that observes it refetches its baseline. The
  environment's `isActive`, set from the app's scene phase, parks every
  retained subscription while false and resumes them when true.
- The transport has one verb. `Transport.send` takes a request and yields
  a stream of payloads: one for a query, the parts of a deferred response,
  the events of a subscription, so a wrapper wraps one method; `payload`
  reads the one payload of a request that answers once. `execute`, `stream`
  and `SubscriptionTransport` are gone, and the environment's
  `subscriptions` is a `Transport`. A `Request` says its `kind` and carries
  the operation's `document`, text or id and never both; the operation's
  `text` and `persistedID` are its `document`, with `text` an optional
  convenience. One `Encoding` turns a request into the JSON a server
  receives, for the HTTP body and the socket's payload alike; the standard
  one writes `query` or `documentId`, and the built-in transports take
  another. They also read `credentials` per attempt, from a closure. Under
  Relay's `persistConfig` in `baton.json` the artifact carries the id,
  hashed with `MD5`, `SHA256` or `SHA1`, and no text, and `batonc generate`
  writes the map from id to text; without it the text and no id. Generated
  code of this shape is format 14.
- A concrete type's lens under an interface or union sees the conditions
  on the interfaces and unions its type satisfies: `... on Character` reads
  the fields `... on Named` selected beside it, under that condition's
  `@include` and `@skip`, as Relay's generated types give each concrete
  variant every field a matching condition selected. The set condition
  keeps its own lens for the types the document does not name.
- A variable of an input object type takes a Swift struct generated for
  the type, declared once per module in the shared file: a property per
  field typed as the schema types it, an initializer with a parameter per
  field, nil for a field left absent, and `variable`, the object the
  request carries. A field name is checked by the compiler where it was
  checked by the server before. Generated code of this shape is format 13.
- What may reach the image is configured. `baton.json`'s `transient` block
  names types whose records are never written and root fields, as
  `Query.search`, whose cells, storage keys and fetch stamps never are,
  since those carry the arguments and variables they were asked with. A
  slot linking to a transient record is left out of its row; the next
  launch misses on it and fetches. Memory is unaffected. The lists join the
  schema's digest, so an image written under another list starts again.
  Generated code of this shape is format 12.
- Client schema extensions, under Relay's key `schemaExtensions` in
  `baton.json`: files, or directories of `.graphql` files, that give server
  types client fields or declare types the server does not have. A client
  field is written by `commitPayload` for an operation that selects it,
  read by a lens like any field, left out of the text and the id a server
  receives, and neither waited for by the availability check nor healed.
  The plan marks each client field; the extensions fold into the schema's
  digest. A non-null client field is refused at its line, and an operation
  of client fields alone at its name. The SwiftPM plugin regenerates when
  an extension changes. Generated code of this shape is format 11.
- A schema enum reads as a Swift enum generated for it, declared once per
  module in the shared file: a case per value the build knows, spelled as
  the schema spells it, and `unknown(String)` for a value it does not, so a
  schema's growth never fails a read. The conversion cannot fail, so the
  accessor keeps the schema's nullability; a null on a non-null field reads
  as `unknown("")` and is reported. Variables and optimistic responses of
  an enum type take the enum. A schema enum named like a fragment or an
  operation is a name error at the document; one named like a shared enum
  or a standard library type takes `Enum` after its name. Generated code of
  this shape is format 10.
- A custom scalar reads as the Swift type `baton.json` maps it to, under
  Relay's key `customScalarTypes`: `"Decimal": "Foundation.Decimal"`. The
  type conforms to `MappedScalar`, an initializer from the scalar's text
  and the text back; `Decimal`, `Date`, `URL` and `UUID` conform, each with
  one format. The store keeps the text; the accessor converts at the read
  and says the conversion can fail: optional wherever the schema puts the
  field, non-optional and throwing under `@required` or
  `@throwOnFieldError`, a `Result` under `@catch` whose failure carries the
  conversion's error. A value that does not convert is reported as
  unexpected and never reads as a zero. A variable of a mapped type takes
  the Swift type and is sent as its text. Generated files import
  Foundation. Generated code of this shape is format 9.
- A lookup takes several arguments. `baton.json`'s `lookups` name the
  arguments that carry a composite key, `"arguments": ["base", "quote"]`,
  one per field of the type's key in its order; `argument` stays the
  spelling for a key of one field. The compiler refuses a lookup whose
  arguments do not match the type's key, and a lookup without a type probes
  only the types one value keys. The runtime composes the arguments' values
  into the record's key as the ingest composes the key fields, so a cached
  `Quote` satisfies `quote(base:, quote:)` before it is fetched. Generated
  code of this shape is format 8.
- Identity is configured. `baton.json`'s `identity` names the fields that
  key a record of each type: a `default` list, `["id"]` unless written, and
  `types` entries for a type or for an interface, whose implementers take
  it. A key is own scalar fields, in order, several of them for a composite
  key, `Quote:base:quote`, each value escaped so that no two lists of values
  meet; a key does not rename, since it is the values at the write. The
  compiler selects the key fields wherever the type is read, as it selects
  `id`, refuses a configuration naming a field a type lacks or cannot key
  by, and the plan names each type's key; the ingest keys a record once
  every key field is read, looking ahead past a link as it did for `id`. A
  configuration other than the default joins the schema's digest, so an
  image keyed the old way is a miss and not a merge. What names a record by
  one value, `@deleteRecord`, `@deleteEdge`, a lookup without a type and
  the image's forget, reaches single-field keys only. Generated code of this
  shape is format 7.
- An owner settles an `@include` or `@skip` condition once, as it resolves
  a key with variables once. Generated code declares each condition as a
  constant, `Guards.<variable>_<value>`, that the plan's fields and the
  lenses' reads both name, and an accessor's read tests the owner's answer
  rather than looking the variable up by name. Generated code of this shape
  is format 6. `Guards` joins the names the compiler keeps: a fragment or
  operation of that name is an error when the module has a condition, a
  field of that name where its lens tests one, and a variable of that name
  where its operation tests one, as with `Sites`; a nested lens that would
  take the name is `GuardsLens`.
- A resolved variant carries the lists its walks need, made once at the
  resolution: the fields a response is read by and the ones a complete
  response must carry, the fields the availability check waits for, the
  connections' client links the check walks for merged pages, and the
  links the collector follows. A walk tests no field for what it is; a
  field's origin, the server, a `@defer` label or the client, is one
  attribute of it.
- An anchor's third word is the record its fragment starts at. A fragment
  spread enters its record as the anchor's origin, and a connection below
  it, however many links down, paginates with that record's id, as its
  fragment's query takes it; before, it passed the id of the record it
  hung from, which a connection one link below its fragment's type got
  wrong. Generated code of this shape is format 5. The test schema's
  `Note` gains `author: Character` for the fixture.
- Membership comes from the response. Whether a type satisfies an
  interface or union condition is a table by the type's number, filled
  from the sets the build compiled and from what responses say in Relay's
  `__isX` fields, which the plan now carries; a type condition in a lens
  is an array load where it was a hash per read. A record of a concrete
  type the build did not list, a type the schema gained after the build,
  takes its variant from the answers: the fields under each condition the
  response says it satisfies, with the ones every type reads, settled once
  per type and per set of conditions. A condition every compiled member
  satisfies is a condition still, since it says nothing of a type the
  build did not list. The image keeps what responses taught for the next
  launch. A lookup without a type probes the members the build compiled.
  Generated code of this shape is format 4; the image's format is 6.
- The plan names the field that keys a record of a type, `id`, and the
  ingest reads that key and knows no field by name; a refetch reads the
  owner's id from the slot its descriptor names. A storage key leaves a
  null argument out, as Relay's does: `notes(after:null,first:2)` is
  `notes(first:2)`, whether the null is a constant in the document or a
  variable given null; an argument that is an object or a list keeps its
  nulls inside. Generated code of this shape is format 3, and an image is
  format 5: both start again. The decision is
  [A storage key leaves a null argument out](docs/decisions/a-storage-key-leaves-a-null-argument-out.md).
- A change set carries where each record's id starts in its key, so the
  store makes the record from it and asks the registry nothing per record
  it creates; an entity's key, `Type:id`, is built in one place, and what
  names a record by a bare value, a deletion, a lookup or the image's
  forget, reads the value part the one way it was written.
- The plan IR carries a field's and a variable's type as one recursive
  shape, a named type or a list of a type with nullability at every level,
  built once in the lowering for the reader side and the normalization
  side alike. With it, a list whose elements the schema types nullable
  reads as an array of optionals, `[String?]`, and a null element reads as
  nil where it was dropped before; a list of non-null elements reports an
  element it cannot hold, a null or a value of another type, once, as a
  scalar reports a value it cannot hold, and leaves it out. A variable
  typed as such a list is a property of the same shape. Generated code of
  this shape is format 2: code of format 1 fails to compile at its marker,
  with a message that says to rebuild. The decision is
  [A list's null elements are typed as the schema says](docs/decisions/a-lists-null-elements-are-typed.md).
- `spec/manifest.json` lists the cases a runtime is held to: each a
  document, its variables, the responses in order, the store's dump after
  them, and what a generated lens reads at each of a set of paths, in a
  language-neutral form `spec/README.md` spells out. The documents the
  manifest names are under `spec/documents/`, written from the generated
  code and checked against it. The oracle tests run the manifest's cases
  and read every row through the generated lens, beside the plan walk they
  ran before.
- The keys a session renders from its variables, one per id looked up and
  per cursor paged past, are numbered by the store that renders them, in
  `Keys`, where the process's registry numbered them for its own life: the
  registry numbers the keys the build names, and nothing a session produces
  is kept in a table of the process. A text has one slot in a store: a
  rendering whose text the build names as a constant takes the constant's
  slot, and a constant the build names after the store rendered its text is
  adopted when the store next resolves, checks or commits: the two slots
  become twins, the records' values are copied across, and every write
  lands in both. A plan is resolved for a store, `Plan.resolve(_:in:)`, and a change
  set made from the resolution is committed into that store; the image's
  writer names a row's slots through the committing store's keys.
  `Slot.storageKey` is gone: a report names a slot through
  `Store.storageKey(of:)`.
- The image sweeps its names with its rows: at a launch's first batch,
  after the rows that aged out go, the names no row uses any more are
  deleted and their ids used again, so the file's table of names is
  bounded by its rows, and the limit of 65,536 names, past which an image
  started again, is gone. The image's format is 4; a file of format 3 is a
  miss and starts again.
- The collector frees the keys a session rendered once nothing can name
  them: a resolution and a lens's scope hold the numbers they took while
  they live, an optimistic layer and a row waiting for the image keep
  theirs, and the rest go with the records the pass sweeps, their numbers
  used again for the next renderings, lowest first, and the image told to
  forget their names. A key a record's row was read under stays numbered
  while the image lives, as the record reads its row once; a root field's
  is freed with the rest and read from the image again. After a long
  session whose roots left, the store's table is the size it was at the
  start.
- The image's file is protected at creation:
  `Persistence(url:version:sizeLimit:protection:)` and the `name:` form take
  a `FileProtectionType`, which Apple's SQLite gives the file and its
  write-ahead log; an image made under another class starts again. A file
  that cannot be taken, locked or full, is waited for, not discarded: the
  writer keeps its work for the next commit or read, where a lost batch
  marked the image behind memory and the next open emptied the cache, so
  every background refresh on a locked device would have emptied it. Work
  that outgrows 50,000 rows is dropped and the image starts again. A marker
  beside the file has the next open finish a removal a crash interrupted or
  a locked device put off; the log is deleted before the database file.
- What the image was told to forget and has not yet dropped is kept behind
  the image's interface, as one value the store holds, where three sets of
  the store's tracked it.
- The image's row is one codec: the tags, the writing of a record's row and
  a root field's cell, and the reading back, in one type over bytes, where
  the writer was the disk's and the reader the hydration's. The disk keeps
  SQLite and knows nothing of the layout; a record's snapshot is the
  record's own type, so the record names the image no more.
- An image belongs to one store. It is made for the store and lives as long
  as it: the environment's end closes it and gives the file back, and the
  next environment makes its own, on that file or another. The count of
  removals a store noted when it was made, which eight of the image's
  functions took to fence a store from before a sign-out, goes: an ended
  store commits nothing, which fences the same with no count.
  `removeAll()` stays as the deletion of the file after the end, which is
  hygiene; what keeps one account's rows from the next is the image's
  identity, the account in its path or in its `version`.
- An environment ends. `await environment.end()` ends the session once and
  for good: it cancels every fetch and stream the environment started,
  drops the roots, clears every record and closes the image, giving its
  file back. An ended store commits nothing, checked at the one door a
  payload takes, so a response that lands after the end, a fetch awaited in
  a task of the app's own or a mutation the server applied, reaches neither
  memory nor the image; a handle still held reads
  `.failed(EnvironmentError.gone)` and tells its observers; every later call
  on the environment throws the same error. A store dropped without an end
  clears its records when it is deallocated, so records that link to each
  other are freed with it.
- A list of links that only grew, a page appended or prepended to a
  connection, drops no link, so it schedules no collection pass of its
  own; a list that changed otherwise still does. The lifetime step's
  numbers are in `BENCHMARKS.md`: a pass over 50,000 records takes 2.8 ms,
  and a page costs about a millisecond more from the eleventh on, the pass
  that follows the root the release buffer pushes out.
- The heal. A read that finds a slot the store never received, which a
  retargeted link leaves behind, marks the owning operation stale and
  refetches it if a holder allows the network, once per fetch of that
  operation; a field still missing after the heal's own refetch is reported
  as unexpected and healed no further. Missing data was reported and left
  to the next attach.
- The fetch policy is the holder's. An attach's policy stays with the
  retention it makes, so a fetch the runtime starts later asks whether any
  holder allows the network: `invalidate()` no longer refetches an
  operation attached `storeOnly`. `Environment.revalidate()` refetches the
  retained operations that are stale or whose last fetch failed, where a
  holder allows the network, and marks nothing: for an app's return to the
  foreground or a connection regained.
- The commit stamps an operation's age. Every server write dates its
  operation, whoever asked for it: a handle's fetch, a refetch, a page,
  `Environment.fetch` or `commitPayload`, and a deferred response when its
  stream completes; the age is the root's, in the store, and a handle reads
  it as `fetchTime`. A query just written that nothing retains waits in the
  release buffer, as Relay's does. Data with no known age is stale wherever
  an expiration applies, in memory as it already was from the image: an
  operation never fetched whose data another operation brought refetches
  under a `storeOrNetwork` attach when a cache expiration applies. The store
  no longer names its environment: a lens fetches through its owner, and
  the phases a commit settles are told through a hook.
- The store owns what keeps records alive. A root, an operation's selection
  and the record it starts from, is the store's, with how many hold it;
  `retain()` returns a `Retention`, a token whose end releases, and
  `release()` is gone: `@Query`'s storage holds the token for the view's
  life, and a model or a view controller holds one in a property. The
  release buffer is `Store(releaseBufferSize:)`, and `collect()`,
  `rootCount` and `collections` are the store's; `Environment` takes no
  buffer size. The collector marks from the roots, the optimistic layers and
  the image's write queue, and from nothing else, and runs when a root left
  or a commit dropped a link: a screen that stays up and refetches is
  collected without another view going away, and a release that only moves
  a root into the buffer runs no pass.
- A query states how old its data may be in its document:
  `@cacheExpiration(seconds:)`, the first directive that is not Relay's,
  which the compiler emits as a constant of the operation and leaves out of
  the text a server receives. The handle reads it with the operation's age;
  an operation that states none takes `Store(cacheExpiration:)`, the
  default given when the store is made. The settable
  `Environment.queryCacheExpiration` is gone: a handle has no one owner, so
  a number set at run time was whoever set it last. The directive is
  refused on a mutation or a subscription, and with a variable.
- A response that omits a field the operation selected fails the fetch as
  malformed, an `IngestError` naming the field and its type, where before
  the handle settled ready and the first read of the field reported missing
  data: a server answers every field it was asked for, so the plan was not
  made for the response. A deferred field is expected in its part, and an
  optimistic response or a payload committed by hand may carry part of the
  selection, as before.
- `Environment.commitPayload(operation, payload)` commits a payload for an
  operation that some other road delivered, a REST response, a socket's
  tick, a preview's fixture or a test's seed, through the same door a
  fetch's response takes: the records merge, the connections and the edge
  directives apply, and the image is written. A payload may carry part of
  what the operation selects.
- One door from a payload to slots. A query's fetch, a deferred stream, a
  mutation, a subscription's event and a page each normalized and
  committed on their own; every payload now passes through one function of
  the environment, which reads it by the plan off the main actor and
  commits it as a server batch, and each entrance keeps only its rule for a
  caller cancelled on the way: a query checks before the commit, a mutation
  does not, since the server applied it, a subscription commits until its
  task ends. An ended store will refuse at that door, the commit will stamp
  the operation's age there, and a report will be raised there.
- The ingest returns what it normalized and no more: a change set holds
  what the store writes, and the parts an incremental response announces,
  whether more follow, and the errors of a part the server could not
  deliver are read beside it rather than carried through the commit. The
  assembly of a stream of parts into change sets, by announced id or by
  path and label, leaves the environment's fetch for a delivery of its
  own; the socket's frame reader leaves the ingest for the transport.
- Nothing outside a batch writes a record. A commit is a batch of one of
  three kinds: server, written to the image; optimistic, whose undo stays
  with its layer; and local, the runtime's own writes, a page's loading
  flag, a lookup's link bound, a link repaired, a cell filled from the
  image, a deferred slot cleared, which were written one by one and
  notified as they happened. The availability check's writes are one local
  batch notified once the walk is over, so an observer that asks the store
  a question from inside a notification sees a whole walk, never one in
  progress; the store no longer keeps the walk's state to guard against
  that. The connection merge and the edge edits are functions over a batch
  in a file of their own.
- A subscription handle's stream is a value beside its events. `stream`
  reads `.idle`, `.connecting` until the first event, `.open`, or
  `.ended(failure)`, with `nil` for the server's completion and a `Failure`
  for an error that ended it; `isActive` is connecting or open. A
  subscription has no loading, since it has no data of its own to wait for,
  so this is not a phase.
- An error keeps its `extensions`. `FieldError.extensions` is the server's
  `extensions` for the error as a JSON value (`Variable`), kept in memory
  and in the image, so an app branches on the server's code and never on
  its message; `GraphQLErrors.errors` carries a request error's errors
  whole, with `messages` still readable. The image's row format moves to
  3, so an image written before starts again, as a cache does.
- A handle's fetch is a value beside its phase. `fetch` on a query value
  and on `OperationHandle` reads `.idle`, `.inFlight`, or
  `.failed(failure, at:)` with the failure and when it failed, so a fetch
  that fails behind data is seen while the phase stays ready, by every view
  of the handle; the next response replaces it. `isRefreshing` is data
  present and a fetch in flight. The failure is a `Failure`, one of a closed
  set of kinds: the transport's, carrying what the transport threw
  unchanged; a request error (`GraphQLErrors`); a malformed response
  (`IngestError`); the environment's (`EnvironmentError`). Field errors are
  not among them. What `phase`'s failed case and `refetch()` carry is the
  error as thrown, as before. Deriving the phase when it is read was decided
  behind a gate, and the gate failed on the bench, so the phase stays
  stored.

## 0.7.0 (Split Time) — 2026-10-05

The ground before the spine: the module's boundaries held by a check, the
compiler refusing what the runtime cannot hold, the plugin telling the truth
about its inputs and outputs, and the numbers the next steps are measured
against, taken before any of them moves anything. The first release that
publishes the compiler's bundle, so a package can depend on Baton by its
tag.

- The bench suite measures what the next steps move, so that each has its
  number before it moves anything: a collection pass over one root that
  reaches 50,000 records, over 300 roots, and the pass that clears a store
  of 50,000 records because no root is left; the re-evaluation a commit
  runs today for a retained `@throwOnFieldError` handle, against the verdict
  a phase read would compute in a body's own tracking scope; and a commit
  with the three report closures set. The numbers are in `BENCHMARKS.md`.
  No iPhone 12-class device was at hand for the suite, and the three
  decision records whose reopening lines wait for one now say so.
- Small truths. `Persistence(name:)` resolves under the app's bundle
  identifier, or the process's name when it has none, so two apps on a Mac
  that both name their image `"Main"` no longer share one file; an app
  upgrading finds an empty image at the new path, which is a cache's lot.
  The public error types are `LocalizedError`s, so `localizedDescription`
  shows the text they carry. Three names that never passed the terminology
  leave the public surface, to go with the steps that remove them:
  `Environment.collect()`, `OperationHandle.settle()` and
  `OperationHandle.isComplete`. The docs tell the truth again where they had
  not: `onError` is `baton.json`'s, not the environment's; a record's
  type-membership bits, configured identity and an introspection command
  are not built, and are marked so or dropped; the lookup entry links the
  decision that stands; `baton.json` takes Relay's key names, and
  `relay.config.json` is not read.
- The collector takes a root's entries with the records it sweeps. A root
  field rendered from variables, `character(id:"7")` or a page after a
  cursor, kept its entry on the root with a blank value after its record
  was collected, so a long session's root held one per id ever looked up;
  the entry now goes with the record, and writing a missing value to such
  a key takes its entry out the same way. The long-session bench looks up
  50,000 ids, where it looked up 2,000, and reports what the process's
  table of keys grows by.
- The hostile-name sweep is a check of the repository:
  `scripts/hostile-name-sweep.py` type-checks, one document at a time, the
  names of fragments, operations and refetch queries the corpus tests prove
  accepted but cannot compile, and every spread form of them, against the
  module just built. CI runs it in the Swift job; it is among the local
  checks.
- The build plugin tells the truth about its inputs and outputs. The
  compiler is among the build command's inputs, so a rebuilt compiler
  regenerates; the compiler removes from its output directory the
  generated files it did not write in this run, so a source renamed or
  removed leaves none behind; and generated code and the runtime share a
  format number, `Types.format` naming `Baton.Format1`, so code of another
  format fails to compile at one line that says which side is behind,
  rather than at every line that names the runtime.
- A field whose type is a list of lists, `[[Int!]!]!`, is a compile error
  at the field. The plan says of a type that it is a list or not, so such
  a field was lowered to a flat list and read wrong; the refusal stands
  until the plan carries a type that can say the depth. A fragment spread
  that reaches the normalization program, which Relay inlines, is an
  internal error rather than a silent skip.
- `RecordedTransport` and `SilentTransport` move to `BatonTesting`, a
  library product of the package for an app's tests and previews, so that
  neither ships in the app. A test or a preview that uses them adds
  `import BatonTesting`.
- The boundaries inside the runtime module are checked:
  `scripts/check-boundaries.sh`, in CI and among the local checks, holds
  the module decision's rules (one file imports SwiftUI, one imports
  SQLite, the record, the plan and the ingest do not name the store, the
  store's files do not name the environment or a transport, and the runtime
  imports nothing else) as a ratchet whose list of tolerated violations
  can only shrink. SwiftUI's part of the runtime, the environment value,
  the storages behind the marker macros and the `ForEach` initializers,
  now sits in one file.
- A custom scalar is its text: a string's contents, or the bytes of any
  other token exactly as the server wrote it, so `1.50`, an integer past
  2^53 and an object or array all read back unchanged. Before, numbers were
  rounded through `Double`, and objects and arrays were stored as null.
- Ingest errors instead of wrong values or traps: an `Int` field given a
  fraction, an exponent or a value outside `Int` fails the response with an
  `IngestError` (it wrapped, rounded, or trapped), and `Int.min` reads. A
  null inside a list of scalars is stored as a null element; it failed the
  whole response. The generated readers, typed as lists of non-optional
  values, still leave such elements out. A `\u` escape cut short by the end of a string, or a high
  surrogate followed by an escape that is not a low surrogate, reads as
  U+FFFD; the first read past the string and the second trapped.
- Storage keys are built from the arguments, not parsed from text. A
  string argument holding `$` (`price(format: "$0.00")`) was read as a
  variable, a lookup argument holding a comma was cut at it, and a list or
  input object with a variable inside was stored under its own text; an
  input object's keys were written unquoted and unsorted. Floats in keys are
  written as the runtime renders a variable. A lookup in `baton.json` whose
  argument the selection does not pass is a compile error.
- Plans know types and conditions. The normalization plan was flat: every
  field of every type condition was expected on every record, so the
  availability check failed right after an operation's own response for any
  selection on an interface or union, and the ingest bound a response key to
  the first field of that name, storing a Location's `label: dimension` in
  its `name`. The compiler now decides, for each abstract selection, the
  fields each group of concrete types reads, and turns `@include` and
  `@skip` into guards the plan settles once per set of variables; the
  ingest reads an object by its type's variant, and the check, collection
  and deferred parts follow the same variants.
- Lenses follow types and conditions. A type condition on an interface
  emitted `asNode` behind a test of the record's concrete type, so it was
  always nil; it is now tested against the set of types that satisfy it,
  emitted once in the shared file, and folds into the parent when every
  type the parent admits satisfies it. An accessor under `@include` or
  `@skip` is optional and reads nil, reporting nothing missing, when its
  condition does not select; `totalCount @include(if: $x)` read 0 and
  reported missing data. A field selected twice, or a fragment spread
  twice, emits one accessor: the file did not compile. An aliased spread
  of a fragment on an interface or union is tested against the types that
  satisfy it; it was always nil.
- A field no variables can select, such as one under `@include(if: $x)`
  and `@skip(if: $x)` at once, is fetched and read under no variables; it
  was planned as always selected, so the check waited for a field the
  server never sends. A field the initial part and a deferred one both
  select is read from the initial payload by its own selection; the
  deferred copy could come first, and the initial fields under it were
  dropped.
- One write path. Everything a batch does, field errors and deletion
  included, is in its undo log and its net notification: a failed
  optimistic write to a field no longer loses the server's error on it, an
  optimistic response that revived a deleted record no longer leaves it
  revived when it fails, and a server commit under a layer that deletes a
  record no longer fires every channel of it twice.
- A deletion is announced to the bodies that hold it. A body that read
  only a list, or a connection's `nodes`, kept a row for a record
  `@deleteRecord` removed, because the slot holding the link did not
  change; the commit that changes whether a record is deleted now notifies
  every slot that links to it, in one pass over the store (2.2 ms for a
  commit that deletes one record from 8,965 on an M1 Pro, against 7 µs
  without the pass). A read of a deleted record's field reports nothing
  missing.
- Identity is the key alone. The store indexed entities by bare id as well,
  last created wins across types, and `@deleteRecord`, `@deleteEdge` and
  lookups without a type resolved through it: in the Rick and Morty data
  `Character:1`, `Location:1` and `Episode:1` coexist, and the index named
  the episode. The index is gone. `@deleteRecord` deletes the one live
  record of any type with the id, and when several types have it deletes
  nothing and calls the new `Store.reportAmbiguousIdentity` (debug builds
  print); `@deleteEdge` drops the edges whose node has the id; a lookup
  without a type probes the field's possible types with the same rule. A
  lookup the image cannot answer no longer leaves an empty record behind.
  `Store.existing(id:)` is removed. An interface is keyed by id when the
  types that implement it have one, as a union is. An object under an
  interface or union that is keyed by its path is a record per concrete
  type; before, a payload of another type at the same path wrote its fields
  into the first type's record. The image's format moved to 2, so an image
  an earlier version wrote is discarded at the next launch.
- `baton.json` is checked: each lookup's field, argument and `type` against
  the schema, and an unknown key is an error.
- A superseded fetch does not commit. A response that arrived, or was still
  being read, after a refetch replaced its fetch landed after the newer one
  when the transport did not hear the cancellation. Ingest now runs in the
  fetch's own task, so cancellation and priority reach it. A mutation's
  request runs apart from its caller's task, and its payload commits
  whoever stopped waiting, because the server applied it; with
  `URLSessionTransport` a cancelled caller cancelled the request, and the
  payload, and an optimistic layer with it, was lost.
- `refetch()` on an operation value and on its handle is `async throws`:
  a refetch that fails throws its error, and the data on screen stays. It
  was dropped before. Breaking: a call site needs `try`.
- `phase` changes only when it changes. A fetch that changed nothing
  assigned an equal `.ready` and re-ran every body that read the phase; a
  ready handle now stays as it is, and so does a failure on the same field
  errors. A `@throwOnFieldError` or bubbling operation's phase follows any
  commit that changes a field error, a null, a link or a deletion in the
  store, not only its own fetch, and a parked one is settled again when a
  view attaches it. Both read the same errors: the operation's own
  selection's, as Relay's reader of the operation does (an error inside a
  spread is the fragment's to weigh), and those its last response carried
  that no field holds. `.networkOnly` no longer sends a handle another
  view shows back to `.loading`, nor reads the store, and the image, to
  decide. A preload's fetch serves the first attach while its data is
  fresh; the attach made a second request when the preload had finished.
- A field error under a parent the server nulled lands on that parent. The
  walk that places an error left a `switch` where it meant to stop, so an
  error at `character.origin.name` with `origin` null was stored on
  `character.name`. An error keeps its whole path, and one with no path, or
  a path that names nothing selected, is kept in
  `ChangeSet.unplacedErrors` and counts as uncaught for
  `@throwOnFieldError`; before, it was dropped.
- Generated code states its isolation: `Types`, `Slots` and every generated
  type are `nonisolated`, readers stay `@MainActor`, so a target built with
  the Xcode template's default of main-actor isolation compiles them (it
  failed on `static let plan`).
- The compiler comes with the package. A package that depends on Baton
  downloads the compiler bundle its release published, named by checksum in
  `Package.swift`; a checkout that built its own with
  `scripts/build-compiler.sh` runs that one (`BATON_COMPILER=local` or
  `release` overrides the choice). The release workflow builds the bundle
  for both Mac architectures and writes the release commit.
- A handle outlives its environment: a view that releases its handle after
  the environment is gone no longer traps; the release does nothing.
- A damaged image is a miss, never a crash. A file damaged under the open
  connection could leave a read stepping a statement already finalized; a
  row with a name id past any table, a link that names no type, or lists
  nested in lists trapped or recursed without bound. Such a row is used as
  far as it reads.
- Each slot is its own invalidation channel. A record had sixteen, so a
  body woke for a change to a field sixteen slots from one it read; on the
  query root, where each field with arguments is a slot, a screen woke for
  root fields other screens fetched (four wakes of an unrelated root-field
  reader in the bench, now none). A tracked read costs about 620 ns against
  560 on an M1 Pro; an untracked read is unchanged at 29 ns.
- A schema whose root types have other names, such as `QueryRoot` or
  `query_root`, works: the compiler interns them by the names the store's
  root records have, `Query`, `Mutation` and `Subscription`, as Relay's
  root record is a `__Root` in any schema. Before, the root fields' slots
  belonged to the schema's type and were written into a record of another.
  A schema that renames a root and also has a type of that root's store
  name, or whose renamed root implements an interface or belongs to a
  union, is an error. `Store(rootType:mutationType:subscriptionType:)` is
  removed.
- Reads never write. A lens read of a root field that was never fetched
  resolved its lookup and wrote the link, notifying, inside the body that
  read it. The availability check binds a lookup before a handle is ready,
  as it did; a lens read of a missing link now reads nil and reports it.
  The `lookup:` parameters of `Anchor.linked`, `requiredLinked` and
  `throwingLinked` are removed. See
  [the decision](docs/decisions/lookups-bind-in-the-check.md).
- Readers say what they could not read. A `required*` reader that finds a
  null reports it through the new `Store.reportUnexpected`, and one that
  finds no value reports the miss; both still return the zero value. A
  value of another kind than the reader's reads nil and is reported; it
  was nil silently. A `@required` field the store never received is
  reported missing before its lens bubbles. A non-null link without a
  record reads one placeholder per type, so the fields below it report
  nothing a second time; a record was allocated per read. A `@catch` on a
  non-null list reports a null as the other readers do.
- A field error inside a type condition, `... on Character { name }` under
  an interface, counts for `@throwOnFieldError` and `@catch` when the
  record is of the type; the lens's error scan skipped the condition.
- A `@required` link to a record `@deleteRecord` removed is null, as every
  other read of the link is: the lens bubbles, a `THROW` collects the
  error, and an operation that bubbles to its root fails. The lens read a
  blank record and the operation stayed ready.
- A connection's `nodes` builds its lenses in one pass instead of an array
  of anchors mapped into a second one: 110 µs for 2,100 nodes against 124
  µs on an M1 Pro.
- A field selected on an interface or union reads through an
  `AbstractSlot`, which resolves its key once per concrete type: 22 ns per
  untracked read against 56 ns, which took the registry's lock and hashed
  the key on every read. The `key:` readers of `Anchor` are removed.
- Keys with variables and fragment arguments are resolved once per owner,
  Relay's fragment owner: the scope a lens reads in, which a handle makes
  once and keeps. A root field with a variable argument rendered its key,
  took the registry's lock and hashed it on every read, 232 ns; it reads
  in 28 ns, against 25 ns for the untracked read of a field with a constant
  key. A spread with `@arguments` built two dictionaries per read and gave
  its child a scope that never compared equal to the last: 453 ns for the
  read and one variable of the child's scope, 45 ns now, and the spread
  alone makes its lens in 10 ns. An
  `Anchor` is a record, an owner and the record it was reached from, and
  two are equal when those are the same objects. Breaking for code that
  builds anchors: `Anchor(record:owner:parent:)` replaces the `parent:`
  form, and `binding` takes the spread's `ArgumentSite`.
- The ingest keeps the last value per field. An entity the response names
  at many paths was written once per appearance and the commit picked the
  winners on the main actor, taking the registry's lock per record; the
  ingest now groups the change set by record, one entry per slot, off the
  main actor. On an M1 Pro, a commit of the fixture's unchanged payload
  takes 152 µs against 182, a commit that changes one field 154 µs against
  185, and the ingest 2.95 ms against 2.78. Placing field errors scans the
  record's entries instead of indexing every entry.
- A commit compares a list where it is stored before building the new
  one, so a list that did not change allocates nothing: the fixture's
  unchanged payload commits in 133 µs against 152.
- A plan resolves once where it can. A handle's fetch uses the resolution
  the handle holds, a selection with no variable below it resolves once
  and keeps the result, and each field's response key bytes and fixed key
  are taken when the static plan is built. Resolving the fixture's plan for
  another page takes 0.69 µs against 8.5 µs without the kept resolutions.
- A subscription frame, an incremental part's envelope and the `errors`
  array are read by a scanner of the response bytes alone; each built the
  plan-driven cursor and its 48 scratch buffers. A 69-byte frame reads in
  375 ns against 2.21 µs.
- A small response costs what it is. The change set reserved room for
  32,768 entries whatever the response, the cursor made 48 scratch buffers
  before reading a byte, and the change set the ingest returned was copied
  on its first append. Reservations now follow the response's size, a
  buffer is made when the walk first reaches its depth, and the change set
  is built where it is filled: a 64-byte mutation payload ingests in 2.4 µs
  against 4.5 µs.
- A floating-point number is read where it lies in the response; each one
  was copied into a new array first, and a number the plan skips was
  parsed.
- A mutation's root fields are keyed without their arguments. Each
  distinct input numbered a permanent slot on `Mutation`, named by the
  input's text; now a field is keyed by its name, or by its alias when it
  has one. The store dumps under `spec/` changed accordingly. The data a
  `mutate` returns is the latest payload of its field.
- The multipart reader drops a preamble, which it returned as a first
  part, lets go of each part once its delimiter is read instead of keeping
  the whole response, and reads a part without headers. It scans the
  chunks it is given rather than a byte at a time: 978 KB of 20 parts in
  16 KB chunks parse in 0.50 ms against 14.6 ms.
- The compiler emits `Types.schemaDigest`, the MD5 of the schema's text, for
  an app to pass as its image's `version`: an image written under another
  schema is discarded. The version is the app's to pass, because generated
  constants are made on first use and nothing has made one when the file
  opens.
- A deferred fragment the image holds only half reads absent, and its
  operation fetches. A record read from the image holds every cell of its
  row, a deferred fragment's link among them, while the records behind it
  may be gone, and the check passes over deferred fields: the fragment
  read present and empty. The deferred fields are now checked apart, in
  memory and then in the image; one whose records are not whole is
  cleared, unless the initial part selects the same field, whose data
  stays, and a store-or-network attach fetches while the initial part
  renders.
- An image that lost a batch, written in vain or dropped while the file
  could not open, is discarded at the next open; it served rows older
  than memory had known, a deleted record among them.
- An edit the store cannot make in memory makes the image forget what it
  would have changed. An edge directive on a connection the store held
  only in the image was dropped, and an insert into the empty record a
  link had made wrote a connection of one edge over the image's; a
  `@deleteRecord` of a record only the image held left it there, to come
  back at the next launch. The connection, or every record with the id,
  is dropped from the image and read as missing until a response gives
  it again, so the screen fetches.
- A read of the image writes nothing first. The availability check wrote
  the writer's whole queue on the main actor before reading, and every
  launch's first reads queued stamps that the next check then wrote there.
  A batch being written lands before a read takes the file, and the
  records of a batch still queued, with those its root fields link to, are
  kept by the collector until written, so a read never meets a row older
  than memory held.
- Data read every launch keeps its age. A fetch time was kept only by the
  fetch that wrote it, so data an app read from the image at every launch
  without fetching went stale at every second launch; a launch that reads
  a fetch time now keeps it for the next.
- `Store.check` says where its answer came from: `.memory`, `.image` or
  `.miss`. A handle took the image's part from a change in a global
  counter, which missed the root's fields and records an earlier check had
  filled, so data from the image without a fetch time could read as fresh.
  `Store.hydratedRecords` is no longer public. Breaking: `check` returned a
  `Bool`.
- `removeAll()` deletes the image's file. It queued deletes that a failed
  open dropped and a failed batch rolled back, and it kept the interned
  names, which hold argument values; work queued before it is dropped
  too. A sign-out releases the old environment's handles, removes the
  image and makes a new environment over it. A store made before the
  removal reads, writes and dates nothing in the image after it, so a
  response that lands late for the user who signed out reaches neither
  the file nor the next user.
- `Persistence.close()` writes what is queued and closes the file, so a new
  image can take it over. The new image counts as a launch, though the
  process is the same: the rows the closed one wrote that it does not read
  age out a launch sooner. A sign-out keeps one image: it removes it and
  hands it to the next environment.
- Opening the image scans nothing. The rows no launch has read since the
  one before last were deleted at open, three scans the first frame
  waited for; a read now treats them as gone and the writer's first batch
  deletes them. A database of another kind at the image's path turns the
  image off for the process instead of being opened again every second.
  The generation moves once per image, not per connection, names are
  written with a plain insert, so a second connection that took an id
  fails its batch instead of renaming every row written with it, and an
  image past 65,536 names starts again.
- One `invalidate`: `Environment.invalidate()`. `Store.invalidate()`, which
  marked memory stale but left the image's fetch times, so data read back
  from the image counted as fresh, is internal and does both.
- Diagnostics point where they are. An error in the schema is positioned
  in the schema file; it printed `1:1`. Related places print as `note:`
  lines, and a message Relay writes over several lines prints on one. A
  state of Relay's programs the lowering relies on never meeting is an
  internal error at the place it was met, where it lowered into an empty
  plan.
- A linked field named `type`, `self`, `protocol` or `any` gets a nested
  lens with `Lens` after its name; it emitted `struct Type` or `struct
  Self`. A selection named or aliased `anchor` or `recordID`, which every
  lens has for itself, is a compile error at the name that asks to alias
  the field or to choose another alias.
- Generated slots are nested per type, `Slots.Character.name`; a type's
  name and a field's ran together, so `A_b.c` and `A.b_c` were both
  `Slots.A_b_c`.
- A variable named like a Swift keyword, `$where` or `$in`, is escaped in
  the operation value; it emitted `public var where`.
- A directive Baton gives no meaning to is a compile error at the
  directive, by place: `@inline`, `@relay(plural:)`, `@relay(mask: false)`,
  `@raw_response_type`, `@preloadable` and `@stream` compiled through
  Relay's transforms and did nothing, or, for `mask: false`, read unmasked
  data that Baton has no word for. A marker holds exactly one definition
  of its own kind: `@Fragment("query …")` and two fragments under one
  `@Query` compiled.
- A persisted id is the MD5 of the operation's text as the app holds it.
  The hash took the printed text with its trailing line break, which the
  emitted `text` drops, so no text the app held matched its id. The ids
  change.
- `onError` is decided at compile time: `"onError"` in `baton.json`, sent
  with every operation the target compiles. Under `NULL` the fields the
  schema types non-null are typed by their semantic nullability, so an
  accessor no longer reads `""` or `0` for a field an error nulled.
  `Environment.errorBehavior`, a switch at run time that changed what the
  compiled types meant, is removed.
- The default fetch policy is `FetchPolicy.default`, `.storeOrNetwork`, as
  Relay's queries default to: the store answers when it can. It was
  `.storeAndNetwork`, spelled in five places, so every attach of every
  screen made a request. Breaking for code that relied on that default:
  name `.storeAndNetwork`. `Environment.releaseBufferSize` is set at init
  and fixed after.
- The data a mutation returns stays readable. Nothing kept its payload
  alive, so after the next collection it read nil; the environment now
  keeps the completed mutation as a root, and its data lives until later
  mutations push it out.
- Kinds are types. An operation value conforms to `Query`, `Mutation` or
  `Subscription`, each refining `Operation`, and each API takes only its
  kind: `handle(for:)`, `preload`, `fetch` and `@Query` queries, `mutate`
  and `@Mutation` mutations, `subscriptionHandle` and `@Subscription`
  subscriptions. A `@Query` holding a mutation compiled, ran on attach and
  wrote the mutation root's slots into the query root. A subscription
  value carries its handle as a query value does; it found it in a table
  of the whole process, keyed by the value, which equal values in two
  environments shared. Breaking: `OperationKind` and `kind` are removed,
  and code generic over operations names the kind it needs.
- A subscription survives a bad event. An event with errors and no data
  ended the subscription for good; it now sets `error` and the stream goes
  on, and the next good event clears it. `retry()` opens a stream the
  server or the socket ended. A stream that a newer one replaced no longer
  closes the newer one's state when it ends. The WebSocket transport reads
  an `error` frame's GraphQL errors as the messages, where it showed the
  frame's text, and closes the socket when its last subscription ends.
- Incremental delivery reads all of the format. A part's `subPath` places
  its data below the announced path, its own `errors` land on the fields
  they name, and an announced part that `completed` with errors puts them
  on the fields it would have filled, where `@catch` reads them; all were
  skipped. A part with `hasNext: false` ends the stream, where the fetch
  waited for the connection to close. Later parts are parsed and
  normalized off the main actor, and the first part's announcements are
  read in the pass that ingests it rather than parsed a second time on
  the main actor.
- A deferred response is fetched when its stream completes, and its fetch
  time is stamped then; it was stamped at the first part, as if the whole
  response had come. A stream that breaks after the first part leaves no
  fetch time, and the deferred parts it lacks make the next store-or-network
  attach fetch again; the first part still renders at once.
- `URLSessionTransport` reads an incremental response from its data task's
  own delegate, in the chunks the loading system delivers; it iterated the
  body a byte at a time. The bench's 978 KB response reads in 1.2 ms
  against 6.1 ms.
- `@defer` in a mutation or a subscription is a compile error. It compiled,
  and the response was read as one part.
- The ingest takes a type's name once per selection rather than from the
  registry, under its lock, for every entity and path key, and reads a
  list of links into a buffer kept per depth rather than a new array per
  list.
- The compiler reads a marker qualified by the module, `@Baton.Query`,
  and raw string literals (`#"""` to `"""#`), in which only a backslash
  followed by the literal's hashes is an escape. A bare `@Query` whose
  first argument is not a string literal, such as SwiftData's
  `@Query(sort:)` or `@Query(FetchDescriptor<Item>())`, is that other macro
  and is left alone; it was an error. The other markers and `@Baton.Query`
  still want a literal. The plugin hands the compiler every file that names
  a marker.
- A `.graphql` or `.gql` file in a target writes its own output; its
  documents compiled and their lenses were never written. Outputs are named
  by the source's path in the target, so `Thing.swift` and `Thing.graphql`,
  or two files of one name in two directories, no longer write one file;
  `batonc generate --out` names them the same way. A `Baton.swift` at the
  target's root that declares GraphQL, whose output would be the shared
  `Baton.baton.swift`, is an error naming it; the shared file overwrote its
  output, or the build failed on two producers of one file. A document with
  an error writes nothing, where every output was overwritten with a stub,
  and a file holding GraphQL that no output is named for is an error.
- Each `batonc` command takes only its own options, and any other is an
  error naming the ones it takes: `--schem x` was ignored, and the schema
  then came from wherever else it could.
- The check that a marker's property is typed as its document's generated
  type finds the definition by its file and its place among the file's
  documents. It searched the document's text for the longest known name, so
  a query that spread `HomeDetail_character` was taken for the operation
  `HomeDetail`. A subscription's property typed `.Action` is now warned
  about; only a mutation's may be.
- A parked `@throwOnFieldError` or bubbling handle that was ready is
  settled again when a view attaches it. A commit made while it was parked
  that put a field error or a null into its selection left it ready; only
  a failed one was settled.
- The first part of a deferred response settles the phase by the errors
  with no path that part carried. It read the last response's, so a
  `@throwOnFieldError` operation whose first part carried one rendered
  ready until the stream completed, and stayed ready when the stream broke
  after it; one whose last response carried one stayed failed until a
  clean response completed.
- A `@throwOnFieldError` operation failed by an error with no path fetches
  again when a view attaches it under `storeOrNetwork`. No record holds
  such an error, so no commit could clear it, and the failure stayed until
  `retry()`. A failure on field errors or a `@required` null, whose data is
  in the store, goes stale as ready data does, so `invalidate()` and the
  expiration refetch it, and a refetch that fails at the transport leaves
  it as it leaves ready data; `isStale` was false for every failure.
- `Environment.fetch(_:)` of a `@throwOnFieldError` operation throws the
  field errors its handle fails on. It threw for every uncaught error the
  response placed, one inside a spread among them, so the fetch threw where
  the handle was ready.
- A stream a retry replaced leaves the new one's `error` alone. A bad
  event the old stream was still reading when `retry()` ran set its errors
  on the handle, and the new stream showed them until its first good event.
- A subscription whose transport ends its stream with a `CancellationError`
  of its own ends: `isActive` is false and the next `retain()` opens it
  again. The handle stayed active over a stream that had ended, and no
  retain could reopen it short of `retry()` or a full release.
- Completed mutations take no place in the release buffer. Each one
  took a place of its own, so ten mutations pushed out the query of a
  screen the user had left, and going back to it loaded and fetched again.
  The environment keeps them apart, one per operation value and as many as
  `releaseBufferSize`, and one pushed out is collected at once; its records
  stayed until some unrelated release scheduled a collection.
- A subscription that opens the WebSocket just after the last one closed
  it keeps its socket. The closed socket's read, failing as it closed,
  ended whichever socket was current, and the new subscription failed with
  a cancellation. Each socket's frames and end now concern that socket
  alone, a socket is not closed while a subscription is opening it or
  starting on it, and the one that opens it no longer waits for an
  acknowledgement that came, or a socket that failed, while its
  `connection_init` was on the way.
- A subscription whose reader goes away before the server acknowledges
  the connection leaves nothing behind: it stops waiting for the
  acknowledgement, and the socket closes when no other subscription is on
  it or starting. The socket stayed open with no subscription on it until a
  later one ended, and without an acknowledgement the subscription's start
  waited for good.
- A `@required(action: LOG)` field below a placeholder logs nothing. Reads
  under a placeholder report nothing, since the non-null link above it was
  reported missing, but a LOG field there still told
  `Environment.requiredFieldMissing`, naming the placeholder's key.
- Floats read as JSON writes them whatever the locale. They were read by
  the thread's locale, in place in the response, so under one with a
  decimal comma `0.25` read as 0, `[1,5]` as `[1.5, 5]`, and a response cut
  off in digits was read past its end; they are read in the C locale now,
  and never past the number the scan found.
- A deferred part the server could not deliver fails an operation the
  same however many errors it sent. Each error after the first was
  unplaced, so with two a part whose fields are all under `@catch` failed a
  `@throwOnFieldError` fetch and handle, and a spread's part failed a
  handle though the spread's fragment weighs its own errors. The errors
  count as uncaught now only when a field the part would have filled is
  under no `@catch`; a part with no field on its record's type leaves them
  all unplaced, where it dropped the first.
- A fragment on the mutation type reads the payload. Its fields kept their
  arguments in their keys while the mutation wrote them without, so a
  mutation that spread it read nil; they are keyed as the mutation's own
  root fields are.
- Of two fields whose lenses would take one name, the second is checked
  through its own lens. Its lens is numbered, `TypesLens2` beside a
  `TypesLens`, but `fieldErrors` and `satisfied` named it again without the
  number and checked the first field's lens, so a field error or a missing
  `@required` field in the second went unseen.
- A linked field named `mainActor`, `double` or `optional` gets a nested
  lens with `Lens` after its name, as `type` and `string` do. Its lens hid
  the attribute on every accessor, the `Double` a `Float` field reads as,
  or the `Optional` a caught spread is wrapped in, and the generated code
  did not compile. The names held back are every type and attribute a
  lens spells unqualified, and Swift's own.
- An edge directive's commit looks no key up by name. Each edit took the
  registry's lock and hashed `edges`, `node`, `cursor` and
  `__connection_next_edge_index` several times; it now edits the
  connection by the slots its plans resolved, which the registry keeps
  under the connection's type. A directive that names a record no
  connection field made, or inserts an edge of another type than the
  connection's edges, leaves it alone; it wrote edges into the record, or
  an edge the connection's readers read by another type's slots.
- The docs say what runs on the main actor: reads, commits, the
  availability check with its reads of the image, collection, and the
  normalization of an optimistic response. The vision, the store principle
  and the README said collection and all normalization ran off it; a
  decision record now says why they do not, with the numbers that would
  move the check and collection.
- A view's storage releases its handle as SwiftUI drops the view's state,
  on the main actor. It released it from a task started for each
  teardown, so the handle stayed retained, and a root, until the task ran.
- A request with nothing to send it fails with `EnvironmentError`, which
  says what is missing: a view's environment, a lens's, the one that made a
  handle and is gone, or a subscription transport. It failed with a
  `TransportError` whose status code was 0 and whose description read as
  an HTTP status.
- An operation whose root a `@required` field bubbled to fails with a
  `RequiredFieldError` that names it in `operationName` and says the root
  bubbled. Its path was the operation's name, so the error described a
  null field of that name.
- A preloaded operation is settled on its first attach. When the preload's
  fetch had finished with fresh data, the attach returned before reading
  the phase again, so a commit that put a field error or a null into the
  selection while the handle waited for a view left it ready.
- A deferred part the server could not deliver lists each of its errors
  once among the uncaught ones. Its first error is placed on every field
  the part would have filled, and was counted once for each such field
  under no `@catch`, so a part of two of them listed it twice.
- A spread alone under an aliased `@catch`, `... @alias(as: "x") @catch {
  ...F }`, compiles whatever the fragment's error policy and reads the
  field errors in the fragment: a failure under `RESULT`, nil under `NULL`.
  It called `F.caught`, which only a fragment with `@throwOnFieldError` had,
  so the generated code did not compile for any other fragment, and under
  `@catch(to: NULL)` such a fragment's accessor threw instead of reading
  nil.
- Every name the generated code declares comes from one allocator per
  scope, which knows the names the scope spells unqualified and the
  program's fragments and operations, and a name the document spells never
  moves. A field aliased `asCharacter` beside `... on Character` declared
  `asCharacter` and `AsCharacter` twice; the condition's accessor and lens
  take the next number, `asCharacter2` and `AsCharacter2`. A field named
  like a fragment or an operation the lens names, such as
  `testNotes_character`, got a lens that hid it; the lens takes `Lens` after
  the name. A spread's accessor named like a field takes the fragment's
  whole name. A connection's `nodes` read `Edges.Node` whatever names those
  lenses took. An optimistic builder for a payload field named `type`,
  `self`, `string` or `sendable` was `struct Type`, hid `String` or
  conformed to itself; it takes `Response` after the name. A name a scope
  would still declare twice is an internal error naming both declarations,
  where the Swift did not compile.
- A variable named `self` is a parameter, a property and a request
  variable of that name. The value's initializer, `variables` and `hash`
  read the instance itself in its place, and the generated code did not
  compile. A variable named `hasher`, or `commit` in a mutation, compiles
  too: `hash(into:)` combined its own parameter in its place, and the
  action called the parameter for its `commit`.
- A plan's edge directive is an `Edit`, as the change set's
  `ChangeSet.Edit` it becomes, so "handle" means only the operation handle.
  Breaking for a plan built by hand: `Handle` is `Edit`, `ResolvedHandle`
  is `ResolvedEdit`, the `handle` properties of `PlanField` and
  `ResolvedField` are `edit`, and `.scalar` and `.linked` take `edit:`.
- A mutation's action passes a variable named like a Swift keyword, such
  as `$self`, by its bare label: Swift warns about an escaped label at a
  call site, and a build that treats warnings as errors refused the
  generated code.
- A key rendered from variables no longer widens the records of its type.
  Each cursor and each id renders a key the process keeps, and keys were
  numbered in one sequence per type, so a field first used after a long
  session was numbered past all of them and every record given it made
  room for each. In the bench's session of 2,000 lookups and 500 pages,
  2,000 characters given such a field took 28.2 MB and 5.86 ms to commit;
  they take 1.1 MB and 1.71 ms. A key the compiler emits as a constant,
  with arguments or without, keeps its place among the type's slots; a
  record keeps the rendered keys written to it in a list of its own
  sorted by key, which a read of one searches by halves: a root field
  with a variable argument reads in 31.6 ns against 28.8 ns, and the
  newest of the session's 2,000 keys in 50.7 ns. A list of 5,000 rows,
  each holding three fields with a variable, commits in 4.76 ms against
  4.08 ms for three constants, and each row holds 96 bytes more. A key
  keeps the kind it is first met as: a constant whose text was rendered
  first, or that the image named first, is read through the search.
  `Slot.index` is negative for a rendered key, and `Registry.slotCount`
  counts both kinds.
- One image in a process holds its file. A second `Persistence` made on a
  file another holds, under any spelling of its path (`/tmp` and
  `/private/tmp`, before the file exists and after), runs without the image,
  as over a database of another kind, and stops a debug build where it is
  made; it opened a second connection, which moved the generation again and
  could fail the first's batches on a name both interned. `close()` and the
  image's end hand the file over; a closed image whose file another has
  taken reads, writes and removes nothing there.
- `RecordedTransport.requests` is read under the lock `execute` appends
  under. It was read without it, so reading it while a request arrived
  off the main actor was a data race.
- A `TransportError` with no response behind it, from a WebSocket that
  closed under a subscription or a `RecordedTransport` with nothing
  recorded for the operation, describes itself by what went wrong; it
  read `HTTP 0: ...`. Its `statusCode` is still 0, now documented as no
  response.
- `isRefreshing` is true while an operation that failed on field errors or a
  `@required` null, with its data in the store, fetches again, and `retry()`
  leaves such a failure in place, its data visible, as `refetch()` does.
  `isRefreshing` was set only behind ready data, so a view showing that data
  and the failure did not see the refetch; `retry()` showed loading over the
  data, and when its fetch failed at the transport the failure became the
  transport's, which no later commit could clear. A handle that shows
  loading is not refreshing: a `networkOnly` view that attached while a
  refetch behind ready data was in flight, and a fetch started behind it,
  kept `isRefreshing` true over a screen that showed nothing.
- A name the document chose that the generated code needs is an error at
  that name, which says what it clashes with and asks for an alias or a
  rename: a variable named `variables`, or `resolution` in a query or a
  subscription; a mutation's payload field named `variable`, which its
  optimistic builder declares; an inline fragment `@alias(as:)` names
  `anchor` or `recordID`, which every lens has; a field named or aliased
  `hasNext`, `hasPrevious`, `isLoadingNext`, `isLoadingPrevious`,
  `connectionID` or `nodes` in a connection; and a fragment or operation
  named `Types`, `Slots` or `Baton`, a refetch query among them. Each was an
  internal error without a position that asked to report it, and a fragment
  named `Baton` hid the runtime's module from the generated code. A fragment
  or operation named `Swift`, `Self` or `Any`, or like a standard library
  name the generated code spells (`String`, `Int`, `Double`, `Bool`,
  `Optional`, `Result`, `MainActor`, `Hasher` or `Sendable`), is such an
  error too: it hid that name from the whole module, and the generated code
  did not compile. So is a field named `Types`, `Slots`, `AbstractSlots` or
  `Sites` where its lens, or a lens nested in it, reads through that shared
  enum, which the field's accessor hid; a variable named `Baton`, `Types` or
  `Slots`, or `AbstractSlots` or `Sites` where the operation's lenses read
  through them, which the variable hid from the operation's code; and a
  mutation's variable named `optimistic`, which its action takes as a
  parameter of its own. A clash between two names the compiler chose stays
  an internal error.
- A field named `Baton` compiles in any lens. A lens under `@catch` or
  `@throwOnFieldError`, a refetchable fragment's and a connection's named
  the runtime's module in expressions, which the field's accessor hid; a
  lens now names it only in types.
- An operation's `text` is a raw literal delimited by one `#` more than the
  longest run of them in the text. A document in a raw literal of two or
  more hashes can hold `\#`, as in `search(name: "\\#1")`, which the
  literal of one hash read as an escape, and the generated code did not
  compile.
- A schema type named `Baton`, `Type`, `Protocol` or `Any` is `Baton_`,
  `Type_`, `Protocol_` or `Any_` in `Types`, at its constant and at every
  reference, as in `Slots`, where a field named `Any` is `Any_` too.
  `Baton` referred to itself in its own initializer and hid the runtime's
  module from the other constants, Swift read `Types.Type` and
  `Types.Protocol` as metatypes, and Swift lets no member be named `Any`,
  so the shared file did not compile. A field or a variable named `Any` is
  escaped where the generated code declares it, as `Type` is. The shared
  file's sets of types are `Swift.Set`, which a type of the module named
  `Set` no longer hides.
- The `RequiredFieldError` of a root that a `@required` field bubbled to
  has the path of that field, the first required field that is null, as
  `character.origin`, and says it: "TestRequiredOrigin: the @required field
  character.origin is null and bubbled to the root". The generated root
  lens, and each lens its check recurses into, has `missingRequiredField`,
  which `Lens` declares and which reads and reports what `satisfied` does;
  `satisfied` is unchanged.
- The store's writes, the ingest and the store's counters belong to the
  package, not to an app: `Store.commit`, `commit(_:replacingOptimistic:)`,
  `applyOptimistic`, `revertOptimistic`, the availability check `check`,
  `optimisticLayers`, `existing`, `invalidationEpoch`, the root records
  and their keys, `ChangeSet`, `Ingest`, the resolved plan
  (`Plan.resolve`, `ResolvedSelection` and its parts), `Store.count`,
  `Environment.collections`, `rootCount`, `unconfigured` and `resolve`,
  the handles' `retainCount`, `MutationState` and the storage-key
  renderings of `Variable` and `Variables` are `package`. The tests and
  benchmarks reach them; an app writes through operations and reads
  through lenses. Breaking for code that committed or ingested by hand.
- The interface generated code calls is SPI, and generated files open with
  `@_spi(Generated) import Baton`. `Anchor`, `Owner`, `Registry`,
  `AbstractSlot`, `DynamicKey`, `ArgumentSite`, the plan types, the
  numbers inside `TypeID` and `Slot`, `Record.read`, `error` and `is`, and
  `Lens`'s `anchor`, `init(anchor:)` and static checks are
  `@_spi(Generated)`, as are an operation's `plan` and its flags; a lens's
  `anchor`, `init(anchor:)`, `connection` and `refetchable` are generated
  as SPI too. An app reads through accessors and cannot rebuild one
  fragment's lens as another's from another module. The `anchor`,
  `init(anchor:)` and `plan` that batonc generates for every lens and
  operation default to a trap, so Baton builds with library evolution, as
  a framework built for distribution builds it; a lens or an operation
  written by hand that leaves them out compiles and traps where it is
  read. `Slot.storageKey` and `TypeID.name` stay public: the store's
  reports hand an app a slot and a record. Breaking for code that read a
  record, built an anchor or a lens, or named a plan: it needs
  `@_spi(Generated) import Baton`, as the tests and benchmarks have.
- A mutation's payload field named or aliased `Baton` compiles. Its
  optimistic builder wrote each scalar as `Baton.Variable(value)`, which
  the field's property hid in the builder and in every builder nested in
  it; a builder now names the runtime's module only in types and writes a
  scalar as `.init(value)`.
- A spread's accessor compiles where a member is named like its fragment:
  a field aliased like the fragment it is spread beside, as
  `TestRow_character: name ...TestRow_character`, a variable of the
  operation, or the accessor itself, which a fragment named in lower case,
  as `fragment row`, gives its name. The accessor spelled the fragment in
  expressions, as `row(anchor: anchor)` and `row.satisfied(anchor)`, which
  the member hid; it now builds the lens as `.init(anchor:)` and calls the
  fragment's checks through a local alias of its type.
- `refetch()`, and a connection's `loadNext` and `loadPrevious`, compile
  where a field is named like the fragment or its refetch query, in the
  fragment's lens or in the connection's. They named both in expressions,
  as `anchor.refetch(TestNotesPaginationQuery.self,
  TestNotes_character.refetchable)`, which the field hid; `refetch()` now
  reads the descriptor as `Self.refetchable`, and the query, and in a
  connection the fragment, are named through local aliases of their
  types.
- A mutation's payload field that is a list of floats or of booleans
  compiles in its optimistic builder, and so does a variable of either
  list type: `Variable` has initializers from `[Double]?` and `[Bool]?`.
  With those from `[String]?`, which lists of strings, IDs, enums and
  custom scalars take, and from `[Int]?`, every list of scalars a builder
  or a variable writes has one.
- A variable that is a list of input objects, such as
  `$filters: [FilterCharacter!]!`, compiles: `Variable` has an initializer
  from a list of variables, which the operation value's `variables` calls.
- A spread that binds sixteen or more of a fragment's arguments compiles,
  and so does the refetch query of a fragment that declares as many. The
  closure that binds them returned a dictionary whose type Swift inferred
  from the literal, which took twice as long with each argument, and Swift
  gave up on it at sixteen; the closure now states its type.
- A spread argument that is a list or an input object holding a variable
  beside a constant, as `@arguments(ids: [$id, "2"])`, compiles. The
  binding defaulted every item to null, `.string("2") ?? .null`, which
  Swift warns about, and a build that treats warnings as errors refused the
  generated code; only a variable, which the scope may lack, is defaulted.
- A field, a selection, an argument or a variable named `rethrows`,
  `fallthrough`, `precedencegroup` or `_` is escaped as Swift's other
  keywords are; the generated code declared `public var rethrows` and
  `var _`, which Swift refuses. A mutation's action passes a variable
  named `$_` by an escaped label, since Swift reads a bare `_:` as no label.
- A variable, or a field of a mutation's payload, named `await` compiles.
  Its value was read bare, as in `self.await = await` and `if let await`,
  where Swift reads the keyword; it is escaped wherever it is declared or
  read.
- A mutation's variable named `$var` or `$let` compiles in a build that
  treats warnings as errors. Its action passed it by an escaped label,
  which Swift, 6.2 as much as 6.3, warns needs no backticks; at a call site
  only `inout` and `_` take them.
- A variable named `hashValue`, or `phase`, `isRefreshing` or `isStale` in
  a query, a refetchable fragment's arguments among them, or `subscription`
  in a subscription, is an error at the variable that asks to rename it.
  Each became a property of the value that took the place of the one the
  runtime gives every such value: `isStale` read the variable where a view
  meant the handle's state, without a word when both were `Bool`, and
  `hashValue` stood beside `Hashable`'s, so the generated code did not
  compile. Swift tells `refetch()` and `retry()` from a property by the
  call, so variables of those names still compile.
- A mutation's payload field named `fields` compiles. Its optimistic
  builder collected the response in a local `fields`, which `if let fields`
  hid; the local takes a name none of the builder's fields binds,
  `fields2`.
- A field or a variable named `Self` compiles beside `@throwOnFieldError`
  and `@catch`. The `caught` check they give a lens built the lens as
  `Self(anchor:)`, which the member hid from that lens and from every lens
  nested in it; it builds it as `.init(anchor:)`. Where a body still
  reaches a lens's own static member through `Self`, as a refetchable
  fragment's `refetch()` and a connection's members do, a field named
  `Self` in that lens or in one around it, or a variable of that name, is
  an error at the name.
- A fragment, a query, a subscription or a refetch query named like a
  Swift keyword, as `fragment class` or `@refetchable(queryName: "each")`,
  compiles. Its name was written bare wherever it stood for a type,
  `public struct class` or `typealias Query = each`; a type a document
  names is escaped wherever the generated code spells it, as a property
  is.
- A mutation named like a Swift keyword, or like what its action declares
  or calls (`Op`, `callAsFunction`, `commit` or `optimistic`), compiles,
  and so does a mutation with a variable named like it, as
  `mutation Favorite($Favorite: ID!)`. The action extended
  `MutationAction where Op == Favorite` and spelled the mutation in its
  signature and its call, `Favorite(Favorite: Favorite)`, where the
  parameter, the action's own members or its type parameter took the
  name's place. It extends `Favorite.Action`, so the mutation is named
  once, where only types are looked up, and its body writes `Op.Data` and
  `self.commit(.init(Favorite: Favorite))`.
- The spread of a fragment named from an underscore, as `..._hidden`,
  compiles. Its accessor took the owner's prefix before the first
  underscore, which is empty, and declared `var : _hidden`; it takes the
  fragment's whole name, `_hidden`.
- A fragment named `Data` is an error at its name where an operation
  spreads it, and so is one named `Action` or `OptimisticResponse` where a
  mutation does. Inside the operation value those names are its own types,
  so the spread's accessor read the fragment as the operation's root lens,
  which compiled and returned the wrong lens, or as the mutation's action
  or builder, which did not compile.

## 0.6.0 (Anchor Leg) — 2026-10-03

The store outlives the process: an image on disk, written behind every
commit, that a launch renders from before the network answers.

- Persistence. `Persistence(url:)`, or `Persistence(name:)` for a file in the
  caches directory, handed to `Store(persistence:)` or to
  `Environment(url:headers:subscriptions:persistence:)`. The image is one
  SQLite file through the system's library: a row per record (flags, the
  type, then a cell per field: storage key, a tagged value, the field's error
  if it has one), the query root a row per field, and type names and storage
  keys interned by name, because slot numbers belong to a process. A commit
  of server data hands the records it changed to a writer, at the cost of an
  array retain each on the main actor; encoding and the transaction run off
  it. What a commit writes under optimistic layers is the server's values:
  a layer never reaches the image, nor do the mutation and subscription
  roots, a connection's loading flags, or the link a lookup wrote back.
- Hydration. The availability check answers from memory first, as before, at
  the cost it had. When memory cannot answer and the store has an image, the
  same walk runs again holding the image's connection in one read
  transaction: a record that lacks a field reads its row once and fills the
  slots it lacks, a missing root field reads its own row, a link to a record
  the collector swept is pointed at the live record of that key, a deleted
  record comes back deleted, and a connection's client record comes back
  with its merged pages. So an operation an earlier launch fetched is
  `.ready` when its handle is made, before the first body, and a screen the
  release buffer let go is read back instead of refetched. Memory wins
  wherever it holds a value. A lookup is satisfied by an entity only the
  image holds, when the lookup names its type. `Store.hydratedRecords`
  counts the rows read.
- Age survives a launch. The image stores when each operation last committed
  a response; a handle whose data is complete and that has not fetched takes
  its age from there, so `isStale`, `queryCacheExpiration` and
  `storeOrNetwork` mean after a launch what they meant before it. Data that
  had to be read from the image and has no fetch time is stale.
  `Environment.invalidate()` forgets the stored times, so an invalidation
  outlives the launch.
- Unreadable is a miss. An image of another format, an image written under
  another `version` (the app's own cache version, for a release whose schema
  gives a field another type), a corrupt file and a file over `sizeLimit`
  (64 MB unless told otherwise) are deleted and started again; a row that
  does not decode is used as far as it reads. A database that is not an image
  is left alone and the store runs without one. A file that cannot be opened
  for any other reason, a device still locked among them, is tried again on
  the next use.
- Lifetime by generation. Every row carries the launch that last wrote or
  read it; at launch, rows no launch has touched since the one before last
  are deleted. A record survives one whole launch unread, and no longer.
- `Persistence.removeAll()` empties the image for a sign-out; `flush()` waits
  for what was committed to be written, for tests and for an app about to be
  suspended.
- The Rick and Morty sample keeps its store on disk: quit and launch again,
  and the list is on screen before the request returns.
- A record's `type`, `key` and `entityID` are `nonisolated`, `entityID` is
  immutable, and `Value` is `Sendable`: another thread may hold a record and
  read its identity.
- The benchmark runs itself as a new process to time a launch, and the
  release's numbers are in `BENCHMARKS.md`: 898 records are in the store
  1.8 ms after their handle asks when the file opened off the main actor,
  under 5 ms when the main actor had to wait for the open. A Mac, not a
  phone.
- Known limits. A record a response writes before the image was asked for it
  replaces its row, so fields only the image held are lost and fetched again
  when a screen needs them. The image is bounded by generations and by
  `sizeLimit` at launch, not by a size-ordered eviction. Reads from the image
  happen on the main actor, inside the check; a read that lands behind a
  write waits for it. One process uses an image.
- Fixed: an entity whose `id` arrives after a linked field is keyed by its
  id. Relay prints the `id` it adds to a selection last and a server answers
  in that order, so the ingest had settled such an object on a path key
  before the `id` came: a second record for the entity, apart from the one
  every other operation writes. In the Rick and Morty sample the detail's
  episodes query moved the root link to that record, and the header read
  missing data until its own response arrived. The ingest now finds the `id`
  and the `__typename` ahead of the first child, in any order; the look ahead
  runs only for an object whose identity follows a link. Two recorded
  responses with the `id` last join `spec/rickandmorty`, and the tests read
  them through the detail's lenses over the list's records.
- Fixed: a refetch or retry during a fetch no longer loses the handle's
  fetch. The superseded fetch used to clear the handle's task and
  `isRefreshing` as it ended, so `isRefreshing` read false with a request in
  flight, `settle()` returned early, the next attach started a duplicate
  request, and eviction could not cancel the live one. A fetch cancelled
  with an error of its own (URLSession reports the cancellation as one)
  could also put a loading handle in `.failed`. A cancelled fetch now leaves
  the handle to whoever cancelled it.
- Fixed: a subscription value's handle is dropped when its last owner
  releases it. `@Subscription` storage used to list the handle on every body
  and nothing took it off, so each subscription value an app ever showed
  kept its handle for the life of the process. The handle now lists itself
  on `retain()` and leaves on the last `release()`, so `subscription` also
  answers for an owner that is not a view.
- Fixed: `GraphQLTransportWebSocket` gives every stream a subscription id of
  its own. It used to look up the subscription to end by operation name and
  variables, so with two equal subscriptions on one socket the end of one
  completed the other, which received nothing more and never finished. The
  transport has its first test over a real socket: the test target runs a
  `graphql-transport-ws` server on the loopback interface.
- The Rick and Morty sample's `baton.json` sits beside the sample, like every
  other target's. The package root has none, so a target without its own
  gets the plugin's warning instead of the sample's schema.
- The Swift emitter has golden tests. `cargo test` compiles the documents of
  the Swift test target as the build plugin does and compares the generated
  files byte for byte with `compiler/src/tests/goldens`, and compiles them
  twice to hold the output deterministic. A change to the emitter or to a
  test document now arrives with its diff of generated code;
  `BATON_BLESS=1 cargo test` rewrites the goldens.
- Continuous integration. A GitHub Actions workflow runs the gates on every
  push to `main` and every pull request: the compiler's `cargo fmt --check`,
  `cargo clippy -D warnings` and `cargo test` on Linux; the package on
  macOS 26 with the current Xcode, every target with warnings as errors, the
  tests in debug and in release, and the library built for iOS; and the
  tests again on Xcode 26.0, the declared floor. The Swift jobs build the
  compiler from the checkout first.

## 0.5.0 (Baton Pass) — 2026-10-03

Honest data on the wire: field errors stored beside their fields, Relay's
error directives in Swift's terms, `@defer` over the incremental formats, and
subscriptions.

- Field errors. The ingest reads a response's `errors`, resolves each `path`
  through the plan to the record and slot it names, and the commit stores the
  error beside the field; a payload that answers the field clears it, and
  either change notifies the field. A plain accessor reads an errored field
  as null, as before; `@catch` reads the error; a cached read sees what the
  network read saw. A response with `data: null` and errors fails the fetch
  with `GraphQLErrors`; errors whose path leads nowhere in the plan are dropped.
- `@required(action:)`. A required field reads non-optional. NONE and LOG
  bubble at the lens boundary, as Relay nulls the enclosing object: the
  accessor that produces a lens (a linked field, a spread, a list element, a
  connection node) produces nil when a required field in it is null, through
  a generated `satisfied`; LOG also reports the path through
  `Environment.requiredFieldMissing`. THROW makes the field's own accessor
  `get throws`, raising `RequiredFieldError`. A root whose required fields
  bubble fails the operation, since there is no null data.
- `@catch(to:)`. RESULT makes the accessor a `Result<T, FieldErrors>` whose
  failure holds the field's error and every error below it, THROW-required
  nulls included; NULL keeps the optional type and reads errors as null.
- `@throwOnFieldError`. On a fragment, the spread accessor is `get throws`
  and throws `FieldErrors` for an uncaught error inside; on an operation, an
  uncaught field error puts the handle in `.failed(FieldErrors)` with the
  data in the store regardless. Under either, and inside `@catch`,
  `@semanticNonNull` fields read non-optional, as Relay types them.
- `Environment.errorBehavior` sends the `onError` request parameter
  (`PROPAGATE`, `NULL`, `ABORT`) when set.
- `@defer`. An operation with a deferred spread asks for `multipart/mixed`
  and reads the parts as they arrive: the first commits and renders, each
  later part is normalized at the record its path names with the fields its
  label marks, and the availability check does not wait for deferred fields.
  Three shapes are read: the June 2023 `incremental[{data, path, label}]`,
  the 2024 `pending`/`incremental[{id, data}]`/`completed`, and Relay's
  `{data, path, label}` per part. A deferred spread's accessor is nil until
  the fragment's fields are present. The schema has to declare `@defer`; a
  server without it gets Relay's "Unknown directive", which is the truth.
- Subscriptions. `@Subscription("…") var live: NoteAddedSubscription` expands
  like `@Query`: the storage subscribes while the view lives and closes the
  stream when it goes; the handle exposes `events`, `latest`, `error` and
  `isActive`. Every event is normalized at `client:root:subscription` and
  committed, so its entities merge and edge directives on a subscription
  payload work. `GraphQLTransportWebSocket` speaks `graphql-transport-ws` over
  `URLSessionWebSocketTask`; `SubscriptionTransport` is the protocol behind
  it, passed as `Environment(transport:subscriptions:)`.
- `Transport.stream(_:)`, with a default that answers once;
  `MultipartParser` splits `multipart/mixed` bodies however the bytes arrive.
- The GitHub sample: `@catch` on the repository lookup shows the server's
  reason for a missing repository; issue rows require an author with
  `@required(action: LOG)`, so an issue without one is no row.

Tests: field errors land beside the field and a plain read, a `@catch` read, a
`@catch(to: NULL)` read and a cached read each see what they should; a
payload that answers an errored field clears the error and notifies; NONE
drops the list element, LOG reports the path, THROW throws at the read;
`@throwOnFieldError` throws at the spread and fails the operation while a
caught error does not; a semantic field reads non-optional; a response with
errors and no data fails with the messages; `onError` is sent; a deferred
fragment is absent after the first part and present after the second in both
incremental formats; a subscription's events commit and append through
`@appendEdge` and the stream closes on release; the multipart parser splits
parts at any chunking. The bench measures a payload with twenty field errors
and the cost of a `@catch` read and a `satisfied` check.

Deliberately not added: `@stream`; operation-level `@catch` (accepted, no
effect; `@throwOnFieldError` is the operation's policy); reconnection and
retry for the WebSocket transport beyond a clean error; `extensions` on
field errors; a sample screen for `@defer` or subscriptions, because neither
public API supports them (both ship on fixtures); the missing-data heal (a
refetch of the owning operation), still planned.

## 0.4.0 (Hand-off) — 2026-10-03

Lists: Relay's connections with pagination, fragment arguments, `@alias(as:)`,
and the declarative edge directives.

- Connections. A field with `@connection(key:)` is read through Relay's
  handle key. The page lands under its server storage key as always; the
  commit then merges it into a connection record keyed by Relay's connection
  id (`<parent>:__<key>_connection(filters)`), as `ConnectionHandler.update`
  does: a page fetched without a cursor becomes the connection, one fetched
  after a cursor appends, one fetched before a cursor prepends, edges
  deduplicate by node, `pageInfo` merges per direction, and a page after a
  cursor that is no longer the end is ignored. The lens over the field
  exposes `nodes`, `hasNext`, `hasPrevious`, `isLoadingNext`,
  `isLoadingPrevious` and `connectionID`; the loading flags are client fields
  on the connection record. Roots mark through the connection as well as
  through the page they fetched, so merged pages live as long as any root
  reaches the connection, whatever fetched them.
- Pagination. A fragment with `@refetchable(queryName:)` whose connection
  takes `first`/`after` from `@argumentDefinitions` gets `loadNext(_:)` on the
  connection lens (`loadPrevious(_:)` for `last`/`before`): the generated
  query runs with the lens's variables, the merged end cursor and the owner's
  id, as a fetch with no handle and no root; the count defaults to the
  argument's default. Every `@refetchable` fragment lens has `refetch()`.
- Fragment arguments. A spread binds the target's `@argumentDefinitions`
  into the child lens's scope over the parent's variables: the passed literal
  or variable, else the default, else null (Relay's fragment variables). A
  storage key with a fragment variable resolves against that scope; the
  normalization and the operation text have the arguments inlined, by Relay.
- Edge directives. `@appendEdge`/`@prependEdge(connections:)`,
  `@appendNode`/`@prependNode(connections:, edgeTypeName:)`,
  `@deleteEdge(connections:)` and `@deleteRecord` become edits the ingest
  records in the change set and the store applies after the entries, under
  the same transaction and undo log, so an optimistic insert shows at once,
  rebases under commits and reverts on failure. `connections` is a variable
  of connection ids (`comments.connectionID`). Inserted edges are copied into
  records the connection owns, numbered by Relay's
  `__connection_next_edge_index`, because a payload's edge record is keyed by
  its path and the next mutation would alias it. A deleted record reads as
  null through links, is skipped by lists and `nodes`, and tells every
  observer; a payload that names it again revives it.
- `@alias(as:)` names the accessor verbatim, for spreads and inline fragments;
  without `as:` the derived names stay.
- Records size their values by what is written, not by the type's slot
  count: a cursor-paginated field registers a storage key per page on its
  parent type, and the other records of that type no longer pay for pages
  they never saw. The scroll bench's footprint fell from +6.5 MB to +4.4 MB.
- `Environment.fetch(_:variables:)` fetches an operation by type without a
  handle. `Anchor` keeps the record it was reached from and binds scopes with
  `binding(_:)`. `ForEach` takes an array of lenses, for `nodes`.
- The GitHub sample: open issues as an infinite-scroll connection on the
  repository screen; comments as a connection with "load more"; the comment
  composer appends through `@appendEdge` instead of refetching the issue; the
  issue screen's spread is aliased. All four read operations were checked
  against the live API.
- The compiler's property-type check takes the longest matching document
  name, so `TestAddNoteFirst.Action` no longer warns about `TestAddNote`.

Tests: two pages merge in order with the last page's info and a stale page is
ignored; a refetch of the first page replaces the merged list and an equal
page notifies nothing; `loadNext` fetches after the end cursor, appends,
toggles `isLoadingNext`, is a no-op at the end and creates no root;
`@appendEdge` and `@prependEdge` insert once per node; an optimistic edge
shows at once, survives a page under it, is replaced by the server's edge and
reverts on failure; `@deleteEdge` removes the edge and `@deleteRecord` makes
the record read as null; `@arguments` binds the scope and defaults apply;
`@alias(as:)` renames. The bench merges 42 pages of 50 notes into one
connection.

Deliberately not added: `@stream_connection` and `prefetchable_pagination`;
refetch with new variables (replace the lens; watch list); null arguments in
storage keys (Relay omits them, Baton renders `null`; both sides agree, and
the format is internal until persistence); page-based lists (watch list);
`@required`, `@catch` and `@defer` (0.5).

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
