# Two runtimes, one compiler

Each runtime is written in its platform's language and feels like it. What
the platforms share is decided before the app runs: the compiler, the plan it
emits, the vocabulary, and the fixtures both runtimes must pass. Nothing is
shared through a bridge.

## Why

A compiler written in Rust makes a shared Rust runtime look natural: one
store, one ingest, one persistence layer, thin bindings. The design forbids
it at its heart. A view body reads a field as a synchronous slot load that
registers with Observation; a Rust record behind a foreign-function call
would hand back a string to copy on every render, or be mirrored by a native
cache that is a second store. The registrar the UI framework tracks is a
native object per record in any case. Whatever walks records (commits,
garbage collection, availability checks, optimistic rebase, connection
merging) lives where the records live. The large native apps that run a
shared C++ core pay for it with materialized native copies of their data,
which is the model this library exists to avoid.

The opposite failure is two runtimes that drift: a response that normalizes
one way on iOS and another on Android, a connection that merges differently,
an error that survives caching on one platform only.

## The idea

Move the shared part to build time. The compiler aggregates fragments,
applies arguments, inserts identity fields, interns storage keys, hashes
persisted ids, and emits a normalization plan per operation and a lens per
fragment. Both runtimes interpret the same plans, so most of the semantics
is computed once, in one language, and the native code is a small
interpreter plus the platform's own networking, observation and storage.

What remains written twice (the tokenizer, the store, retention, connections,
the persisted row codec) is specified by language-neutral fixtures: recorded
responses with the store contents and lens reads they must produce. A
divergence is a failing test on both sides.

## Consequences

- The Swift runtime depends on Foundation, Observation and the SQLite the
  system ships; the Kotlin runtime on the platform's equivalents. No native
  library ships inside either.
- A platform developer can read, fix and vendor their runtime without the
  other platform's toolchain.
- Networking uses the platform stack, with its TLS, proxies, background
  behavior and HTTP/3.
- The compiler is the only Rust a user ever runs, and it runs on the build
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
step owns, [The response is the oracle](response-is-the-oracle.md) for the
fixtures, and the decision record
[Native runtimes, not a shared core](../decisions/native-runtimes.md) for the
measurements and the one condition under which this bends.

## Spelled today

`swift/` holds the Swift runtime, its macros, its build plugin, its
benchmarks and its tests; `compiler/` holds `batonc`, which emits Swift;
`spec/` holds the schemas, the responses and the store dumps a runtime is
held to. There is no Kotlin runtime yet, and `batonc` has no Kotlin
emitter. This section may rot; the rest must not.
