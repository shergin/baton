# Native runtimes, not a shared core

Status: accepted, 2026-10-02. Serves
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Reopen when the Kotlin tokenizer cannot meet the ingest budget on the JVM;
the contained remedy is a Rust ingest library for Android only, producing a
flat change-set buffer that the Kotlin store applies, with iOS unchanged.

## Context

Fetching, ingest, the store, retention, optimistic updates and persistence
could be written once in Rust and bound into Swift and Kotlin, as several
sync and messaging SDKs do, or written twice in the platform languages. The
compiler is already Rust.

## Decision

Both runtimes are native. Rust runs only on the build machine. Equivalence
comes from the compiler's plans and the shared fixtures, not from shared
code.

## Evidence

- A native lens read measured 6.5 ns on an M1 Pro (spike, 2026-10-02). A read
  across a foreign-function boundary returns a string that must be copied
  into a native string on every render, or cached natively, which is a second
  store.
- The observation registrar is a native object per record on both platforms;
  a Rust record would need a native shadow anyway.
- Store algorithms walk records; with native records they must be native, or
  cross the boundary per record.
- Meta's shared C++ client hands product code immutable generated native
  models, which are copies; LinkedIn's did the same. Both are the
  materialization this library removes.
- Generated bindings inherited default main-actor isolation in Xcode 26 and
  broke for UniFFI, swift-protobuf and openapi-generator users in 2025–26.
- A lean Rust core adds two to four megabytes per platform and a second
  toolchain for every contributor.

## Not chosen

- A shared Rust core with UniFFI or JNI bindings: the read path above.
- A canonical Rust store with a native read replica: two stores, double
  memory, a sync protocol, and copies in views.
- A Kotlin Multiplatform core consumed from Swift: Objective-C-shaped APIs,
  flows and suspend functions that need extra tooling to feel native, and
  no Observation integration.
- A Swift core on Android through the official Swift SDK: Compose needs
  Kotlin records regardless, and Swift–Kotlin bridging is immature.
