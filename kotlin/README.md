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
(`Generated.kt`), and the lens's skeleton (`Lens.kt`). The store, the
ingest and the readers follow.
