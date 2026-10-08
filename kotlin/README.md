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
goldens/   compiles the Kotlin emitter's goldens, compiler/src/tests/goldens-kotlin, against the runtime
```

`scripts/check-kotlin-goldens.sh` runs `:goldens:compileKotlinJvm`.

## Building

A JDK 21 and Gradle 9; the project's `gradle.properties` sets nothing
machine-specific, so point `JAVA_HOME` at the JDK. The tests run the
specification through the code `batonc` generates from `spec/sources`, so
build the compiler first; the build takes the binary `BATON_COMPILER`
names, as a Gradle property or in the environment, else
`compiler/target/release/batonc`, else `compiler/target/debug/batonc`:

```bash
(cd ../compiler && cargo build --release)
JAVA_HOME=$(/usr/libexec/java_home -v 21) gradle :baton:build
```

## Where it stands

The plan model generated code constructs (`Plan.kt`, `Registry.kt`), the
wire's values (`Value.kt`), the operation interfaces (`Operation.kt`), the
host markers (`Markers.kt`), the generated-code marker and the format
(`Generated.kt`), and the public errors (`Errors.kt`).

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
62, through the plans `batonc` generates from `spec/sources` into the
package `baton.spec`, as an app's build would. A first
number, not a benchmark: the Fixture response (686 KB, 899 records) is
ingested in about 1.7 ms and committed in about 0.3 ms on JDK 21 on an M1
Pro, the medians `IngestTiming` prints.

The reads. The anchor's readers are every accessor generated code calls
(`Lens.kt`): a read loads one cell on the store's thread, so composition
registers that slot alone; a missing or wrong-kind value goes to the
store's log and reads as null or a zero value; a non-null link with no
record reads the type's placeholder, the link alone reported; `@required`,
`@catch`, `@throwOnFieldError` and `@defer` read by Relay's rules. The
owner settles a lens's keys, conditions and `@arguments` once each
(`Owner.kt`). `jvmTest` reads every `reads` row of every case through the
generated lenses, walking a row's path over their properties, with mapped
scalars through the converters `spec/tests/baton.json` names for
`BigDecimal`, `Instant` and `URI`, and asserts the rule each row's `note`
names.

The generated code is whole: a fragment's lens and an operation's `Data`
over the readers, an `@inline` fragment's value, a connection's state and
its `loadNext`, a `@refetchable` fragment's `refetch()`, a mutation's
`OptimisticResponse` and the `invoke` its `MutationAction` is called
through. What those fetch and commit through is the environment's.

The availability check, optimistic layers, retention and collection, the
image and the environment, with pagination and refetch, follow.
