# The Kotlin runtime is common first, and a platform is an actual

Status: accepted, 2026-10-07. Serves
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Answers [#24](https://github.com/shergin/baton/issues/24) and shapes
[#6](https://github.com/shergin/baton/issues/6). Not built yet. Reopen when
a target's actual cannot meet the ingest budget
[Native runtimes, not a shared core](native-runtimes.md) names, or when
common code needs a platform API the standard library lacks.

## Context

Issue #24 asks that the Kotlin runtime be a Kotlin Multiplatform library
from its first commit: the store, the ingest, the lenses, retention,
connections and persistence in `commonMain`, with `expect` and `actual` for
the platform's SQLite, HTTP client, WebSocket and lifecycle, so Compose
Multiplatform targets get Baton with no third runtime. It argues that
retrofitting Multiplatform onto an Android library touches every file, and
it says this does not reopen the native-runtimes record, which refused a
Kotlin Multiplatform core consumed from Swift.

The principle fixes the number of runtimes by language, and says the Swift
runtime depends on Foundation, Observation and the system's SQLite, and the
Kotlin runtime on the platform's equivalents.

## Decision

- `commonMain` holds everything the principle calls the runtime.
- `expect` and `actual` cover the image's engine, the transports and the
  activity signal, and nothing else.
- Android is the first actual.
- The platform's equivalents of Foundation, Observation and the system's
  SQLite are the Kotlin standard library, kotlinx-coroutines, the Compose
  runtime and the platform's SQLite, and nothing else: no Ktor, no
  serialization library, no bundled engine.
- The native-runtimes record is not reopened. A Kotlin app on iOS is Kotlin
  reading Kotlin records; a SwiftUI app reads the Swift runtime.
- A target without SQLite, such as wasmJs, runs without an image or behind
  the image's interface. Which one is a later decision.

## Evidence

- Issue #24, read 2026-10-07: the source sets it proposes, one per target
  with `commonMain` holding the store and the ingest; its argument that an
  Android-first runtime costs a rewrite to port; its note that a Kotlin
  runtime on Kotlin/Native iOS is not the core consumed from Swift that the
  native-runtimes record refuses; and its observation that wasmJs has no
  SQLite.
- [Native runtimes, not a shared core](native-runtimes.md): its refusal
  names a Kotlin Multiplatform core consumed from Swift, for Swift's sake:
  Objective-C-shaped APIs and no Observation integration. Kotlin reading
  Kotlin records meets none of it.
- [Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md),
  *Consequences*: no native library ships inside either runtime, and
  networking uses the platform stack.
- Nothing is measured yet. The ingest budget the native-runtimes record
  owes is the first number the Kotlin lane takes.

## Not chosen

- Android first, then a port: a rewrite of every file the port touches.
- A Kotlin runtime consumed from Swift: refused already, by the principle
  and by the native-runtimes record.
