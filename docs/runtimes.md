# The two runtimes, one map

The Swift and the Kotlin runtimes are one machine written twice
([the decision](decisions/native-runtimes.md)): the same concepts, the same
mechanisms, the same fixtures under `spec/`. A reader moving between them
finds a mechanism under the same file name in both trees, and this map is
where that is checked: `scripts/check-boundaries.sh` fails when a file
named here is missing from its tree, or when a runtime source file is not
on the map. A row is a concept or a mechanism of
[the vocabulary](terminology.md); a cell names the files that hold it.
Swift's files are under `swift/Sources/Baton/`; Kotlin's under
`kotlin/baton/src/commonMain/kotlin/baton/`, with a platform's actuals
named by their source set.

| Concept or mechanism | Swift | Kotlin |
|---|---|---|
| The store: records by key, batches, layers, the commit | `Store.swift` | `Store.kt` |
| Records and values | `Record.swift`, `Value.swift` | `Record.kt`, `Value.kt` |
| Scalars as the store keeps them: text, and a double's digits | `Scalars.swift` | `Text.kt`, `jvmSharedMain/Doubles.jvmShared.kt`, `jvmMain/Doubles.jvm.kt`, `androidMain/Doubles.android.kt` |
| The ingest: scanner, cursor, change set | `Ingest.swift` | `Ingest.kt`, `Cursor.kt`, `ChangeSet.kt` |
| The plan, and the format the generated code names | `Plan.swift` | `Plan.kt`, `Generated.kt`, `Markers.kt` |
| Resolution: a plan for one set of variables | `Resolution.swift` | `Resolution.kt` |
| Membership: which types satisfy which abstract type | `Membership.swift` | `Membership.kt` |
| Lenses and owners | `Lens.swift`, `Owner.swift` | `Lens.kt`, `Owner.kt` |
| Keys and the registry | `Keys.swift`, `Registry.swift` | `Keys.kt`, `Registry.kt` |
| Connections: the merge of a page, the edge directives' edits | `Connections.swift` | `Connections.kt` |
| Roots, the verdict, retention, collection | `Roots.swift` | `Roots.kt` |
| Operation values, policies, the phase | `Operation.swift` | `Operation.kt` |
| The handle | `Handle.swift` | `Handle.kt` |
| The subscription | `Subscription.swift` | `Subscription.kt` |
| The availability check | `Availability.swift` | `Availability.kt` |
| Hydration from the image | `Hydration.swift` | `Hydration.kt` |
| The environment, the one door | `Environment.swift` | `Environment.kt` |
| Transports, framing, payloads | `Transport.swift`, `Payload.swift` | `Transport.kt`, `Framing.kt`, `Payload.kt`, `jvmSharedMain/HttpTransport.kt`, `jvmMain/GraphQLTransportWebSocket.kt` |
| Delivery of payloads to handles | `Delivery.swift` | `Delivery.kt` |
| The image: persistence, the disk, the row codec | `Persistence.swift`, `Disk.swift`, `Row.swift` | `Persistence.kt`, `Disk.kt`, `Row.kt`, `Image.kt`, `jvmSharedMain/Image.jvmShared.kt`, `jvmMain/Image.jvm.kt`, `androidMain/Image.android.kt` |
| The host's observation | `SwiftUI.swift`, `Macros.swift` | `Compose.kt` |
| Threads | the main actor and the ingest's actor, in the files above | `Threads.kt`, `jvmSharedMain/Threads.jvmShared.kt` |
| Log and errors | `Log.swift`, `Errors.swift` | `Log.kt`, `Errors.kt` |
| Inspection: the store as `spec/` freezes it | the `BatonInspector` product | `Dump.kt` |

What differs is the host and the platform: Swift observes through
Observation and the macros, Kotlin through Compose's snapshot state;
Swift's threads are actors, Kotlin's are dispatchers and a lock; the image
sits on the system's SQLite in Swift and on the AndroidX driver in Kotlin.
A mechanism in one tree and not the other is a gap, listed in the
changelog until it closes.
