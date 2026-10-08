# The Kotlin runtime is common first, and a platform is an actual

Status: accepted, 2026-10-07; amended 2026-10-07, the first actual, and
the primitives a target supplies; amended 2026-10-07, the platform's
SQLite reached through the AndroidX SQLite driver API; the Android actual
built, 2026-10-07. Serves
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md).
Answers [#24](https://github.com/shergin/baton/issues/24) and shapes
[#6](https://github.com/shergin/baton/issues/6). Reopen when
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
  activity signal, and the two primitives common Kotlin lacks that the
  runtime cannot do without: a thread's identity, by which the store is
  held to the thread that created it, and a double's shortest text, by
  which a key renders a float as the contract spells it. Nothing else.
- The JVM is the first actual and the development target, through
  Compose for Desktop: the runtime is built, the oracle and the scripts
  run, and the host API is designed on a Mac, with no emulator in the
  loop. Android is the first shipped target and the ingest budget's home;
  its actual follows once the JVM's passes the fixtures, and the record
  layout and the transports are called settled only after the budget is
  measured there.
- The platform's equivalents of Foundation, Observation and the system's
  SQLite are the Kotlin standard library, kotlinx-coroutines, the Compose
  runtime and the platform's SQLite, and nothing else: no Ktor, no
  serialization library, no bundled engine. The platform's SQLite is
  reached through the AndroidX SQLite driver API (`androidx.sqlite:sqlite`,
  interfaces alone: `SQLiteDriver`, `SQLiteConnection`, `SQLiteStatement`),
  which `commonMain` depends on and the image is written against; a target
  supplies the driver. Android's will be `AndroidSQLiteDriver`, over the
  system's library. The JVM has no SQLite of its own; its image actual
  takes `BundledSQLiteDriver` (`androidx.sqlite:sqlite-bundled`) as a
  dependency of that target alone, and nothing of it reaches `commonMain`
  or Android. The image's actual is the driver and what SQL cannot do
  around it: the file operations, the directory the platform keeps cached
  data in, the writer's thread and a lock, which common Kotlin lacks.
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
- The amendment, 2026-10-07: the Compose runtime the store is observed
  through is one artifact on the JVM and on Android, so what the desktop
  proves about observation holds on the device; a JVM test cycle is
  seconds against an emulator's minutes. What the desktop hides is
  named so it is measured and not assumed: HotSpot's escape analysis
  hides allocations ART charges for, and the desktop JVM has a WebSocket
  client where Android's platform has `HttpURLConnection` alone.

- The amendment of the driver API, 2026-10-07: the image of the Swift
  runtime is built on it whole, its six tables, its blobs, its
  transactions, its pragmas and its eviction, and the twelve scripts run
  through it, `ages` and `check` across a relaunch. Two things the API does
  not carry are worked around: a failure's result code reaches common code
  only in the exception's message (`Error code: 26, ...`), which the image
  reads to tell a file to discard from one to wait for; and the file's size
  is the database's pages (`page_count` times `page_size`), since common
  Kotlin has no file system. A protection class has no counterpart on
  these platforms and the Kotlin image takes none.

- The Android actual, 2026-10-07: `jvmSharedMain`, a source set the JVM
  and Android share, holds the HTTP transport, the thread's identity and
  the image's file operations, writer and lock; `androidMain` holds
  `AndroidSQLiteDriver` and a double's shortest text; the socket transport
  stays the JVM's. Three differences the device showed, each held by a
  device test: the framework adds `android_metadata` to every database it
  opens, so a new image is told by its tables but that one; Android's
  driver fails a step past the one row `PRAGMA journal_mode=WAL` answers,
  so the mode is set in one step; and Android's `Double.toString` is not
  the shortest round trip (`8.409999999999999E21` for `8.41e21`), so the
  digits are searched for there. A corrupt file is deleted by the
  framework when it opens it. The runtime holds no `Context`:
  `Persistence.named` takes the app's cache directory on Android. The
  lowest Android is 6 (API 23), the Compose runtime's and AndroidX
  SQLite's. `IngestBenchmark` from a release build on the owner's Google
  Pixel 9 (Android 17) ingests the Fixture response in about 5.1 ms and
  commits it in about 1.3 ms, the medians of 300 runs; the debuggable
  device-test build took 19 ms and 6.7 ms, and the emulator's release
  numbers are 4.3 ms and 1.1 ms (`BENCHMARKS.md`, 2026-10-07). The
  native-runtimes record carries the number as the budget's evidence.

## Not chosen

- Android first, then a port: a rewrite of every file the port touches.
- A main-thread check as an actual: the store is confined to the thread
  that created it instead, which is the main thread in an app and the test
  thread in a test, so the platform's notion of main is never asked.
- Android as the development target: an emulator and the Android Gradle
  plugin on every iteration of a runtime none of whose common code is
  Android's.
- A Kotlin runtime consumed from Swift: refused already, by the principle
  and by the native-runtimes record.
