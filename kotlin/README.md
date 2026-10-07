# Baton for Kotlin

The Kotlin runtime, common first with a platform as an actual, as
`docs/decisions/the-kotlin-runtime-is-common-first.md` records: the store,
the ingest, the lenses, retention, connections and persistence in
`commonMain`; the image's engine, the transports and the activity signal as
each target's actual. The JVM, through Compose for Desktop, is the
development target; Android is the first shipped one.

What a runtime does is `spec/runtime.md`; what it is held to is the
manifest, the sources, the cases and the scripts under `spec/`. The host
API is designed in the private notes before it is built.

## Layout

```
baton/     the runtime: commonMain, jvmMain (androidMain later); jvmTest runs the spec
scripts/   the plans' transcriber, until the Kotlin emitter prints plans
```

## Building

A JDK 21 and Gradle 9; the project's `gradle.properties` sets nothing
machine-specific, so point `JAVA_HOME` at the JDK:

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 21) gradle :baton:build
```

## Where it stands

The plan model generated code constructs (`Plan.kt`, `Registry.kt`), the
wire's values (`Value.kt`), the operation interfaces (`Operation.kt`), the
host markers (`Markers.kt`), the generated-code marker and the format
(`Generated.kt`), and the lens's skeleton (`Lens.kt`).

The store and the ingest, to the dump. A record's cells are Compose
snapshot state, one per slot (`Record.kt`); the store numbers the keys a
session renders and adopts a constant the build names after (`Keys.kt`);
a plan is resolved under the store's keys (`Resolution.kt`); a response's
bytes become a change set by the plan with no tree between
(`Ingest.kt`, `Cursor.kt`, `ChangeSet.kt`), deferred parts by their paths
(`Delivery.kt`); the commit writes it, merges connections and applies edge
directives (`Store.kt`); and `Store.dump()` writes the `*.store.json`
text. The store belongs to the thread that made it.

`jvmTest` holds it to every case of `spec/manifest.json`: each case's
responses committed into an empty store leave its dump byte for byte, all
62. The plans are transcribed from the Swift goldens by
`scripts/transcribe-plans.py` until the Kotlin emitter prints them. A first
number, not a benchmark: the Fixture response (686 KB, 899 records) is
ingested in about 1.7 ms and committed in about 0.3 ms on JDK 21 on an M1
Pro, the medians `IngestTiming` prints.

The lens's readers, the availability check, optimistic layers, retention
and collection, the image and the environment follow.
