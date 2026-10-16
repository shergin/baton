# Two runtimes, one compiler

Each runtime is written in its platform's language and feels like it, and
nothing is shared through a bridge.

What the platforms share is decided before the app runs: the compiler, the
plan it emits, the vocabulary, and the fixtures both runtimes must pass.

## Why

A compiler written in Rust makes a shared Rust runtime look natural: one
store, one ingest, one persistence layer, thin bindings. The design forbids
that runtime, at its heart. A view body reads a field as a synchronous slot
load that registers with Observation. A Rust record behind a foreign-function
call would hand back a string to copy on every render, or be mirrored by a
native cache that is a second store. The registrar the UI framework tracks
is a native object per record in any case. Whatever walks records lives
where the records live: commits, garbage collection, availability checks,
optimistic rebase, connection merging. The large native apps that run a
shared C++ core pay for it with materialized native copies of their data.
That is the model this library exists to avoid.

The opposite failure is two runtimes that drift: a response normalizes one
way on iOS and another on Android, a connection merges differently, and an
error survives caching on one platform only.

## The idea

Move the shared part to build time. The compiler aggregates fragments,
applies arguments and inserts identity fields. It interns storage keys and
hashes persisted ids, then emits a normalization plan per operation and a
lens per fragment. Both runtimes interpret the same plans, so most of the
semantics is computed once, in one language. The native code is a small
interpreter, plus the platform's own networking, observation and storage.

What remains written twice is the tokenizer, the store, retention,
connections and the image, specified in files no language owns. The runtime
contract says what a runtime does with a plan, a response and a store, and
the fixtures are recorded responses, with the store contents and lens reads
they must produce. A divergence is a failing test on both sides. The
image's bytes are each runtime's own, and what is shared is that a second
store over the image reads the same records.

## Consequences

- The Swift runtime depends on Foundation, Observation and the SQLite the
  system ships, and the Kotlin runtime depends on the platform's
  equivalents. No native library ships inside either.
- You can read, fix and vendor your runtime without the other platform's
  toolchain.
- Networking uses the platform stack, with its TLS, proxies, background
  behavior and HTTP/3.
- The compiler is the only Rust you ever run, and it runs on the build
  machine, never on the phone.
- Every runtime feature lands with its fixture, and the fixture is shared.

## Not this

- A shared Rust core with foreign-function bindings, however thin.
- A canonical store in one language mirrored by a read cache in another.
- A Kotlin Multiplatform core consumed from Swift, or a Swift core consumed
  from Kotlin.
- Any runtime behavior that exists in one platform's implementation and not
  in the fixtures.

See [The compiler decides](compiler-decides.md) for what the shared build
step owns. See [The response is the oracle](response-is-the-oracle.md) for
the fixtures. The decision record
[Native runtimes, not a shared core](../decisions/native-runtimes.md) has the
measurements, and the one condition under which this bends.

## Spelled today

`swift/` holds the Swift runtime, its macros, its build plugin, its
benchmarks and its tests. `kotlin/` holds the Kotlin runtime, common first,
with the JVM and Android as its actuals, its Gradle plugin, its benchmarks
and its tests. `compiler/` holds `batonc`, which emits Swift and Kotlin from
one plan. `spec/` holds the schemas, the documents, the responses, the store
dumps and the expected reads both runtimes are held to, listed in
`spec/manifest.json`, and `spec/runtime.md`, the contract. The contract is
the rules that produce them, each naming the fixture that holds it or marked
unheld. Compose Multiplatform is the Kotlin runtime on more targets, not a
third runtime
([The Kotlin runtime is common first](../decisions/the-kotlin-runtime-is-common-first.md)).
This section may rot. The rest must not.
