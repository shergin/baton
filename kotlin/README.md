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
baton/          the runtime: commonMain, jvmMain (androidMain later); jvmTest runs the spec
baton-testing/  the transports an app's tests run over: scripted, recorded, silent
goldens/        compiles the Kotlin emitter's goldens, compiler/src/tests/goldens-kotlin, against the runtime
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
through.

The environment (`Environment.kt`) and what hangs off it. A request and
its standard encoding, and a transport with one verb, a `Flow` of payloads
(`Transport.kt`); the value-free log (`Log.kt`). The environment commits on
its main dispatcher, the store's thread, and reads responses on its ingest
dispatcher; a query's fetch checks for cancellation before its commit, a
mutation's request and commit run where no cancellation reaches them, and
`end()` cancels, clears and forgets the session. A handle (`Handle.kt`)
applies its fetch policy and derives its phase from its root and its
fetch, both read through Compose snapshot state; `refetch()`, `retry()`
and `retain()`, whose `Retention` is released by hand. The store keeps the
roots (`Roots.kt`): retention and the release buffer, ages and staleness,
the verdict settled after a batch that changed a null, a link, an error
or a deletion, and the collector, which frees the records no root reaches
and the numbers no root, scope or fetch holds. The availability check binds
lookups in memory (`Availability.kt`), and a read that finds data missing
heals its root once per fetch. `baton-testing` holds `ScriptedTransport`,
`RecordedTransport`, `SilentTransport` and `wait`.

`jvmTest` runs every script of `spec/manifest.json` through one
environment and one store over a `ScriptedTransport`, on a test
dispatcher, comparing after each step what the Swift harness compares:
the dump, the reads, the slots notified (through Compose's apply
observer), the phases and fetches, the log, the bodies sent and what the
step threw. `notifications`, `phase`, `lifetime`, `events`, `end`,
`transport`, `heal` and `connections` pass whole; `ages` and `check` to
their `relaunch`, which needs the image; `subscriptions` waits from its
first step and `optimistic` from its first commit under a layer, since an
optimistic response is written for now as a plain batch of its kind.

The optimistic layers, subscriptions, pagination's `loadNext` and a
fragment's `refetch()`, the composables, the image and the HTTP and socket
transports follow.
