# Gradle: the runtime from Maven Central, and the compiler as a task

`com.shergin.baton` is [the command's contract](batonc.md) spelled in
Gradle: a task that runs `batonc generate` with every input and output
declared and yields the generated Kotlin for the source set the adopter
already has, over a compiler the plugin fetches from the release's artifact
bundle. It lives under `kotlin/baton-gradle` in this repository and is
versioned with Baton, so the plugin 0.15.0 fetches the bundle 0.15.0
published and writes the format the runtime 0.15.0 reads; the version the
snippets below quote is the latest release, as `CHANGELOG.md` names it. It holds no logic
of its own: which source writes which output, the header for a source
without GraphQL, the shared file, staleness and diagnostics are the
compiler's ([the decision](../decisions/a-build-integration-holds-no-logic.md)).

## The runtime

The Kotlin runtime is on Maven Central from 0.13.0, as Kotlin Multiplatform
artifacts with a JVM and an Android target, so one coordinate resolves to
the variant a module compiles against:

| Coordinate | What | Targets |
|---|---|---|
| `com.shergin.baton:baton` | the runtime: the store, the lenses, the environment, the transports, the image | JVM, Android |
| `com.shergin.baton:baton-testing` | `ScriptedTransport`, `RecordedTransport`, `SilentTransport`, `wait` and the `SocketServer` double, for an app's tests | JVM; Android from 0.14.0 |
| `com.shergin.baton:baton-okhttp` | `OkHttpTransport` and `OkHttpWebSocketClient`, the transports over an app's OkHttp client, and the socket Android's platform lacks; from 0.14.0 | JVM, Android |
| `com.shergin.baton:baton-inspector` | `StoreInspector`, a live Compose view of a store for a debug pane, and `StoreExport` | JVM, Android |

The runtime depends on the Compose runtime, which generated code names
(`@Stable`), kotlinx-coroutines and the AndroidX SQLite driver API, with
the bundled driver on the JVM; Compose UI is the app's own. On Android it
starts at API 23, and it needs no R8 or ProGuard rules and ships none: the
runtime, its modules and the generated Kotlin use no reflection, no
serialization and no lookup of a class or a member by name, so a minified
build keeps what the code calls. The AndroidX pieces
are on Google's Maven repository, which Gradle does not search unless the
build names it, so the settings name `google()` beside `mavenCentral()` for
dependencies, as the snippet below does. The runtime is built with Kotlin
2.4.20 and carries Java 21 class files, so a consumer runs on a JVM of 21
or newer and compiles with Kotlin 2.4 or newer; the floors and the policy
behind them are
[the decision](../decisions/kotlin-floors.md).

## The plugin

The plugin is on Maven Central beside the runtime, not on the Gradle plugin
portal, so the settings name that repository for plugins once, and Google's
beside it for the runtime's dependencies:

```kotlin
// settings.gradle.kts
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}
```

The module that holds the screens applies it beside the Kotlin plugin,
names its hosts, and adds the task's output to the source set that compiles
them; a Multiplatform module here, where a JVM-only module applies
`kotlin("jvm")`, adds the directory to `sourceSets.main` and declares the
dependency at the top level:

```kotlin
// build.gradle.kts
import baton.gradle.BatonGenerate

plugins {
    kotlin("multiplatform") version "2.4.20"
    id("com.shergin.baton") version "0.15.0"
}

// The hosts: every Kotlin file the compiler scans for `@Fragment`, `@Query`,
// `@Mutation` and `@Subscription`, and any `.graphql` document beside them.
val generateBaton = tasks.named<BatonGenerate>("generateBaton") {
    hosts.from(fileTree("src/commonMain/kotlin") { include("**/*.kt", "**/*.graphql") })
}

kotlin {
    // The module's targets; the generated Kotlin compiles for each.
    jvm()
    sourceSets {
        commonMain {
            kotlin.srcDir(generateBaton.flatMap { it.outputDirectory })
            dependencies {
                implementation("com.shergin.baton:baton:0.15.0")
            }
        }
    }
}
```

An Android application module adds the directory through the variant API
instead, which is how `kotlin/benchmarks/android` does it:

```kotlin
androidComponents {
    onVariants { variant ->
        variant.sources.kotlin?.addGeneratedSourceDirectory(generateBaton, BatonGenerate::outputDirectory)
    }
}
```

`baton.json` is read from the module's directory by convention, with the
schema, the identity, the lookups and the scalars as
[the vocabulary](../terminology.md) defines them and
[the compiler's recipe](batonc.md) reads them, and
`"kotlin": {"package": "<package>"}` for the shared file.

The compiler is the release's: on first use the plugin downloads
`batonc.artifactbundle.zip` of the release it is versioned with, the one
file SwiftPM and Bazel download, checks it against the checksum the release
wrote into `kotlin/release.properties`, unpacks it whole into
`caches/baton/<version>/batonc.artifactbundle/` under the Gradle user
home, once per home, and runs the variant
its `info.json` lists for the host, macOS or Linux, x86_64 or aarch64. A checkout that
builds its own compiler names it instead, as `Package.swift` and the Bazel
extension take `BATON_COMPILER`, a `batonc` binary or a bundle directory
holding an `info.json`:

```bash
BATON_COMPILER=/path/to/batonc gradle build
```

or, for every task of a project, `baton { compiler.set(file("...")) }`. An
offline build with no bundle cached fails and says so.

## `BatonGenerate`

The plugin registers one, `generateBaton`; a module with documents against
two schemas registers a second with the task type.

| Property | What | Convention |
|---|---|---|
| `hosts` | the sources the compiler reads: `.kt` hosts and `.graphql` documents | none; the task fails without them |
| `configuration` | `baton.json` | the module's own |
| `schema` | a schema in place of the configuration's, passed as `--schema`, for one that is a build's output | unset |
| `workingDirectory` | where the compiler runs; a host under it is passed by its relative path | the module's directory |
| `outputDirectory` | the generated Kotlin, one file per host and the shared `Baton.baton.kt` | `build/generated/baton/<task>` |
| `report` | what the run compiled, as `--report` writes it | `build/baton/<task>/report.json` |
| `persisted` | the persisted documents file under `persistConfig`, as `--persisted` places it | unset, so it goes under the output directory |

- **Every input declared:** the hosts, the configuration, and the schema
  and the `schemaExtensions` the configuration names, which the plugin reads
  from its text through a provider Gradle tracks, so an edit to the schema
  regenerates and the adopter names nothing twice; the compiler binary when
  `BATON_COMPILER` names one, and the release's version and checksum when it
  does not. The task is cacheable and runs under the configuration cache.
- **One output per source,** named as the SwiftPM plugin and the Bazel rule
  name it: the host's path relative to the working directory, each separator
  an underscore, `.baton.kt` in place of `.kt` and after any other extension
  (`src/commonMain/kotlin/app/Screen.kt` writes
  `src_commonMain_kotlin_app_Screen.baton.kt`); a renamed source leaves
  nothing behind, since the compiler removes what it did not write.
- **Diagnostics** are `path:line:column: error: message`, pointing into the
  GraphQL text in the host file, which Gradle and the IDE show at the line;
  a document with an error fails the task with nothing written.
