# Floors at Android 6, Java 21 and the current Kotlin

Status: accepted, 2026-10-09. Serves
[Two runtimes, one compiler](../principles/two-runtimes-one-compiler.md),
beside [Floors at the 26 releases](platform-floors.md), the Swift
runtime's. Reopen when an adopter needs an older Android, JVM or Kotlin,
when a target beyond the JVM and Android is built, or at the 1.0 review.

## Context

The Swift runtime's floor is the newest Apple releases, because the runtime
is built on what they added. The Kotlin runtime is built on the Kotlin
standard library, kotlinx-coroutines, the Compose runtime and the AndroidX
SQLite driver API, which run on an old Android and on any recent JVM, so
no platform release sets its floor. What does is the dependencies on
Android, the JDK the artifacts are compiled with on the JVM, and the
Kotlin the generated code and the hosts need. Until this record the three
lived in the version catalog and the build files alone, and the JVM target
was whatever JDK ran the build: a local build on JDK 26 wrote Java 26
class files where the release, built on JDK 21, had written Java 21.

## Decision

- Android 6, API 23: the lowest the Compose runtime and AndroidX SQLite
  allow, so the floor is the dependencies' and moves when theirs does. The
  runtime compiles against API 36, and the modules with Compose UI, the
  inspector and the samples, against API 37.
- Java 21: the runtime and its modules, `baton`, `baton-testing`,
  `baton-inspector` and `baton-okhttp`, are compiled with a JDK 21
  toolchain and carry Java 21 class files on the JVM and on Android alike,
  the long-term release the release workflow builds with. The build pins it
  with `jvmToolchain(21)`, so a build on another machine writes the same
  files or fails saying which JDK it lacks; building needs a JDK 21 and
  Gradle 9.
- Kotlin 2.4.20, the current release, moved to each new one with the
  catalog; an adopter compiles with the same or a newer one. The generated
  Kotlin and the hosts use what the current language has: `data object`,
  value classes, and in a host the `$$"""…"""` multi-dollar string, which
  Kotlin 2.2 made stable; the runtime reads `kotlin.concurrent.atomics`
  behind its experimental opt-in. An older Kotlin reading a newer
  artifact's metadata is not tested here and not promised.
- The dependencies at this record: Compose Multiplatform 1.12.1 for the
  Compose runtime, kotlinx-coroutines 1.11.0, AndroidX SQLite 2.7.1, and
  for `baton-okhttp` OkHttp 5.5.0. The numbers' home is
  `kotlin/gradle/libs.versions.toml`, which a release moves; this record
  names the policy and the floors it gave on its date.

## Evidence

- The published 0.14.0 artifacts on Maven Central, read 2026-10-09:
  `baton-jvm-0.14.0.jar` and the `classes.jar` inside
  `baton-android-0.14.0.aar` carry class files of major version 65, Java
  21, and the AAR's manifest declares `minSdkVersion="23"`.
- The manifests of the Compose runtime's `runtime-android` 1.12.1 and of
  AndroidX SQLite's `sqlite-android` and `sqlite-framework-android` 2.7.1
  declare `minSdkVersion="23"`.
- `.github/workflows/release.yml` and the CI kotlin job set up JDK 21. A
  local build on JDK 26 before the pin wrote class files of major version
  70; after it, 65 on either JDK.
- No device older than Android 17 has run the runtime: the ingest budget
  and the end-to-end numbers in `BENCHMARKS.md` are a Pixel 9's. The
  Android floor is the dependencies' declaration, not a measurement.

## Not chosen

- Java 17 class files, the Gradle plugin's own target and the usual Android
  choice: the release has built on JDK 21 since the first publication,
  Compose for Desktop asks 17 and the Android Gradle plugin accepts 21, so
  17 would admit no adopter 21 shuts out and would make the artifacts
  differ from what shipped.
- A JVM target left to the JDK running the build: a local build and the
  release disagreed, which is how this record was found wanting.
- Android 5, API 21, Compose UI's floor: the Compose runtime 1.12 and
  AndroidX SQLite 2.7 start at 23, and nothing of Baton would run below
  it.
- A Kotlin older than the current release held for adopters: the hosts'
  multi-dollar strings need 2.2 at least, and holding the runtime to an
  older compiler would cost what each release adds for nothing an adopter
  has asked for.
