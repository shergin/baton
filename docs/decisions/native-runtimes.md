# Native runtimes, not a shared core

Status: accepted, 2026-10-02; the ingest budget's first device number,
2026-10-07. Serves
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

- The first number on a named device, 2026-10-07 (`BENCHMARKS.md`, "the
  Kotlin ingest on a device"): on the owner's Google Pixel 9 (Tensor G4,
  Android 17), a debuggable device-test build, the 899-record fixture
  tokenizes in 19.0 ms off the main thread and commits in 6.7 ms on it,
  the medians of 300 runs after 200. The commit fits a 60 Hz and a 120 Hz
  frame; the ingest runs off the frame. The JVM does the same in 1.7 ms
  and 0.3 ms, so ART's allocation cost is what the Kotlin tokenizer and
  change set pay, and that is the first thing to measure and trim before
  the remedy this record names is weighed. A release build that is not
  debuggable (`kotlin/benchmarks/android`), the same device and day,
  takes 5.1 ms and 1.3 ms, three and four times the JVM.

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
