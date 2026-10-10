# Porting from Relay

Baton keeps Relay's words and directives, so a Relay app ports by spelling,
not by rethinking: a fragment stays a fragment, a connection a connection,
`@required` and `@catch` mean what they mean. What differs is what Swift,
Kotlin and a native runtime make better, and what Baton leaves out on
purpose. The table gives each word in Swift and in Kotlin; each "not this"
below links its reason.

## The same words

| Relay | Baton, in Swift | Baton, in Kotlin |
|---|---|---|
| `graphql\`fragment X on T {...}\`` and `useFragment` | `@Fragment("fragment X on T {...}") var x: X`, a lens: a typed, read-only view over one record, synchronous on the main actor | `@Fragment("fragment X on T {...}")` on the composable that takes `x: X`; the same lens, synchronous on the store's thread |
| `useLazyLoadQuery` | `@Query("query Q {...}") var q: Q` in a view; `q.phase` is `.loading`, `.ready(data)` or `.failed(error)` | `@Query("query Q {...}")` on the composable and `val q = rememberQuery(Q(...))`; `q.phase` is `Phase.Loading`, `Phase.Ready(data)` or `Phase.Failed(error)` |
| `useMutation` and `commitMutation` with `optimisticResponse` | `@Mutation("mutation M {...}") var m: M`, called as an action, or `environment.mutate(M(...), optimistic:)` | `@Mutation("mutation M {...}")` and `val m = rememberMutation(M)`, called `m(..., optimistic = ...)`, or `environment.mutate(M(...), optimistic)` |
| `useSubscription` | `@Subscription("subscription S {...}") var s: S`; the handle reconnects by a fixed backoff and parks while the app is inactive | `@Subscription("subscription S {...}")` and `rememberSubscription(S(...))`, the handle, which reconnects and parks the same way |
| `usePaginationFragment`, `@connection`, `loadNext` | `@connection` on the fragment, `@refetchable(queryName:)`, and `loadNext(count)` on the lens | The same directives; `loadNext(count)` on the lens, a `suspend` function |
| `useRefetchableFragment` | `@refetchable(queryName:)` and `refetch()` on the lens | The same; `refetch()` is a `suspend` function |
| `@required(action: NONE / LOG / THROW)`, `@catch`, `@throwOnFieldError` | The same directives; `@catch` reads as `Result`, `@required(action: THROW)` and `@throwOnFieldError` fail the phase, `LOG` logs through the environment's `log` | The same; `@catch` reads as `kotlin.Result`, THROW's getter throws `RequiredFieldError`, and the phase and the log as in Swift |
| `@defer` | `@defer`; the first part renders, `isPresent` says whether the rest arrived | `@defer`; the spread's getter is null until the rest arrived, which the companion's `isPresent(anchor)` says |
| `@inline` and `readInlineData` | `@inline`; the fragment compiles to a `Sendable`, `Hashable` struct, and the spread's accessor on the parent's lens builds it when called, on the main actor | `@inline`; the fragment compiles to a `data class`, built by the spread's getter when called, on the store's thread |
| `@argumentDefinitions`, `@arguments` | The same | The same |
| `RelayEnvironmentProvider` | `.environment(\.baton, environment)` | `CompositionLocalProvider(LocalBaton provides environment)` |
| `Environment` with `Network.create(fetch, subscribe)` | `Environment(transport:subscriptions:)`; a transport has one verb, `send`, yielding a stream of payloads | `Environment(transport, subscriptions)`; `send` returns a `Flow` of payloads |
| `persistConfig` and `persisted-queries.json` | `persistConfig` in `baton.json`; an operation carries its id, the file is written by the build | The same; the Gradle task's `persisted` property places the file |
| `commitPayload(operationDescriptor, payload)` | `environment.commitPayload(Q(...), Payload(data))` | `environment.commitPayload(Q(...), Payload(bytes))`, a `suspend` function |
| `RecordSource` persisted by hand | `Persistence(name:version:)`: an image on disk the launch renders from | `Persistence.named(name, version = ...)` or `Persistence(path)`, handed to `Store(persistence)`; on Android under the app's `cacheDir` |
| `environment.getStore().invalidateStore()` | `environment.invalidate()`; `revalidate()` refetches what is stale when the app returns | The same |
| `fetchPolicy: 'store-or-network'` and friends | `FetchPolicy` on `handle(for:fetchPolicy:)`: `storeOrNetwork`, `networkOnly`, `storeOnly`, `storeAndNetwork` | `FetchPolicy` on `rememberQuery(operation, fetchPolicy)` and `handle(operation, fetchPolicy)`: `STORE_OR_NETWORK`, `NETWORK_ONLY`, `STORE_ONLY`, `STORE_AND_NETWORK` |
| `log: LogFunction` | `environment.log`, a closure of value-free `LogEvent`s | `environment.log`, a function of value-free `LogEvent`s |
| `relay-compiler` | `batonc`, Relay's front end behind a Swift emitter; a build plugin runs it, or the command line does | `batonc` with its Kotlin emitter; the Gradle plugin `com.shergin.baton` runs it |

## Different on purpose

- **Missing data heals itself.** Relay suspends on missing data; Baton's
  lens reads nil, records the miss, logs it and refetches the operation that
  owns the record. Nothing in a view waits.
- **Identity is configured, not assumed.** `id` keys a record by default;
  types keyed otherwise, including composite keys and interfaces, are named
  in `baton.json`, and the compiler asks the server for the key fields.
- **Custom scalars read as the app's types.** `customScalarTypes` maps a
  scalar to `Decimal`, `Date`, `URL`, `UUID` or the app's own
  `MappedScalar`, as a string or under `swift` in an object by language,
  and under `kotlin` to a Kotlin type with the `ScalarConverter` object
  for it; the conversion happens at the read, and a value the type cannot
  hold is a field error.
- **Enums are generated**, with a case for a value the build did not know:
  Swift's `unknown`, Kotlin's `Undeclared`.
- **Input objects are generated values**, a struct in Swift and a data
  class in Kotlin, typed from the schema.
- **The session is the environment.** Signing out is `await environment.end()`,
  a `suspend` call in Kotlin, and a new environment; there is no
  `replaceStore`.
- **Client fields are described and committed**, through `schemaExtensions`
  and `commitPayload`; there are no resolvers and no `commitLocalUpdate`.

## Not ported, and why

| Relay | Why not | What reopens it |
|---|---|---|
| Resolvers, live resolvers, `commitLocalUpdate`, `@updatable`, `@assignable` | A second way to write and logic in the store; a payload for an operation says every write | A write no payload for an operation can say |
| `@module`, `@match` | Code splitting is a bundler's concern | none |
| Reader snapshots, `seenRecords`, store subscriptions | Observation and Compose's snapshot state do what they do, per field | none |
| Suspense, the missed-update epoch | Reads are synchronous; the heal refetches | none |
| Generator-based GC | A pass runs whole on the store's thread, once a turn after a root left or a commit dropped a link: 2.8 ms over 50,000 records ([why](../decisions/the-check-and-collection-run-on-the-main-actor.md)) | A pass that misses a frame |
| `invalidateRecord` | Ages belong to the operation, not the record | A product that must mark one entity stale |
| `@stream`, `@stream_connection` | No server in use emits them | A server in use that does |
| Imperative store updaters | Directives and payloads have expressed every write so far | A real write neither can express |
| Automatic persisted queries | They need text and id at run time; the working group dropped them | none |

Relay's docs stay the reference for the directives' meaning. Baton's
[terminology](../terminology.md) is the contract for every word above.
