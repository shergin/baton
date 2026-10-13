# Two runtimes, no bridge

Baton's compiler is written in Rust, and the obvious next step is a runtime
written in Rust too: one store, one ingest, one persistence layer, bound into
Swift and Kotlin behind thin wrappers. Several sync and messaging SDKs ship
that way, and Meta's own native GraphQL client is a C++ core with wrappers.
Baton refuses it. The Swift runtime is Swift, the Kotlin runtime is Kotlin,
and Rust runs only on the build machine. The runtime is written twice on
purpose, and what holds the two to one behaviour is not shared code but a
shared compiler, a shared contract and shared fixtures.

## The read path forbids a bridge

The design's whole point is that a view reads a field as a synchronous slot
load that registers with the UI framework's observation. On an Apple M1 Pro
that read costs 26 ns; on the JVM 22 ns; on a Google Pixel 9 47 ns
([BENCHMARKS.md](../../BENCHMARKS.md), the 0.1.0 entry and the Apollo Kotlin
rerun of 8 October 2026). A record behind a foreign-function boundary cannot
offer that. A read across the boundary returns a string that has to be copied
into a native string on every render, or the native side caches what it read,
which is a second store with a synchronization problem. Either way the view
holds a copy, and copies are the materialization this library exists to
remove.

The registrar the framework tracks is a native object per record in any case:
Observation's in Swift, a snapshot-state channel per slot in Kotlin. A Rust
record would need a native shadow to be observable at all. And everything that
walks records lives where the records live: the commit, collection, the
availability check, the optimistic rebase, the connection merge. With native
records those walks are native, or they cross the boundary once per record.

Meta's shared C++ core hands product code immutable generated native models,
which are copies, and LinkedIn's did the same; Meta's own 2023 guidance for
its iOS app is that product-facing code should no longer contain C++.
Generated bindings inherited default main-actor isolation in Xcode 26 and
broke for UniFFI, swift-protobuf and openapi-generator users in 2025 and 2026.
A lean Rust core adds two to four megabytes per platform and a second
toolchain for every contributor. The decision record has the list ([Native
runtimes, not a shared core](../decisions/native-runtimes.md)).

## What is shared instead

Move the shared part to build time. The compiler aggregates fragments, applies
arguments, inserts identity fields, computes storage keys, hashes persisted
ids, and emits a normalization plan per operation and a lens per fragment.
Both runtimes interpret the same plans, so most of the semantics is computed
once, in one language, and the native code is a small interpreter plus the
platform's own networking, observation and storage. One plan, two emitters:
the generated Swift and the generated Kotlin for an operation carry the same
selections, the same storage keys and the same kinds.

What remains written twice, the tokenizer, the store, retention, connections,
the image, is specified in files no language owns:

- [The runtime contract](../../spec/runtime.md), one paragraph a rule, each
  naming the fixture that holds it or marked unheld.
- [The fixtures](../../spec/README.md): schemas, the authors' documents with
  their client directives, recorded responses, the records a store must hold
  after each one as a dump in Relay's `__ref` shape, the reads a generated
  lens must answer, and scripts over time for phases, notifications, lifetime,
  optimistic layers, connections, the availability check, the heal and
  streams.
- The harvest of Relay's own store tests, translated into Baton's keys and run
  on both runtimes ([the
  decision](../decisions/relays-tests-are-measured-not-obeyed.md)).

A divergence is a failing test on both sides. The image's bytes are each
runtime's own; what is shared is that a second store over the image reads the
same records.

## How the second runtime was written

The Kotlin runtime was written in October 2026 against the fixtures the Swift
runtime already passed, and the order it was built in is the argument for the
arrangement. First the store and the ingest to the dump: records as snapshot
state per slot, keys numbered by the store, the tokenizer over bytes, until
every case's dump matched byte for byte, with plans transcribed from the Swift
goldens until the Kotlin emitter printed them. Then the readers and lenses,
until every expected read of every operation answered. Then the environment,
handles, phases, retention and collection, run through the scripted transport
until every script passed. Only then the image over the AndroidX SQLite
driver, the HTTP and WebSocket transports, the Compose integration, and a
sample on a device.

Two findings from that port shaped both runtimes, which is what a second
implementation is for. A list element reads as the scalar of its type does,
which the contract said and the Swift lists did not do, so Swift was aligned.
And a subscription with no transport retried on its backoff forever, since
only a request error ended a stream, so both runtimes now end a stream on an
environment failure as they do on a request error.

The Kotlin runtime is common Kotlin first, with the JVM and Android as its
actuals: a platform supplies the file operations, the SQLite driver, the
socket and the dispatcher, and nothing else ([the
decision](../decisions/the-kotlin-runtime-is-common-first.md)). Compose
Multiplatform is the same runtime on more targets, not a third one.

## What the two runtimes cost on their platforms

The fixture's 899 records; the Swift row is the 0.1.0 entry of 2 October 2026,
a release build, and the Kotlin rows are "the Kotlin ingest on a device" of 7
October, the phone a release build and the JVM row a timing that entry gives
for scale rather than a benchmark ([BENCHMARKS.md](../../BENCHMARKS.md)):

| Where | Ingest, off the main thread | Commit, on the main thread |
|---|---|---|
| Apple M1 Pro, the Swift runtime | 2.14 ms | 1.24 ms |
| The JVM on the same Mac, the Kotlin runtime | 1.7 ms | 0.3 ms |
| Google Pixel 9, the Kotlin runtime | 5.1 ms | 1.3 ms |

The commit, the main thread's share, takes a sixth of a 120 Hz frame on the
phone. The phone runs the same Kotlin three to four times slower than the JVM,
which is ART's allocation cost, and the decision record names the contained
remedy if the Kotlin tokenizer ever fails its budget: a Rust ingest library
for Android only, producing a flat change set the Kotlin store applies, with
iOS unchanged. Nothing today asks for it.

## What differs, by design

The two runtimes are one machine, and [the map](../runtimes.md) puts a
mechanism under the same file name in both trees, checked by a script that
fails when a file is missing from either. What differs is the host and the
platform. Swift observes through Observation and the marker macros; Kotlin
through snapshot state and annotations on the composable, with a document
carried in a `$$` raw string because a GraphQL variable's `$` is a Kotlin
template. Swift's threads are actors; Kotlin's are dispatchers and a lock. The
image sits on the system's SQLite in Swift and on the AndroidX driver in
Kotlin. A Swift accessor that can throw is a Kotlin getter that throws;
`@catch` reads as a `Result` on both. A Swift `AsyncSequence` is a Kotlin
`Flow`. Each runtime feels like its platform wrote it, which is the other half
of the principle ([Two runtimes, one
compiler](../principles/two-runtimes-one-compiler.md)).

## What an adopter gets

The Swift runtime depends on Foundation, Observation and the SQLite the system
ships; the Kotlin runtime on the platform's equivalents. No native library
ships inside either, and the compiler is the only Rust a user ever runs,
prebuilt, on the build machine. Networking is the platform's stack, with its
TLS, its proxies, its background behaviour and its HTTP/3. A platform
developer can read, fix and vendor their runtime without the other platform's
toolchain.

And a team on both platforms gets one vocabulary and one set of guarantees.
The same fragment compiles for both; the same response normalizes into the
same records; the same field error survives caching on both; the same script
of phases holds on both. That is a stronger equivalence than a shared binary
gives, because it is checked where it matters, at the behaviour, and it costs
the read path nothing.
