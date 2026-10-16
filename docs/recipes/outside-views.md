# Outside views: data for code that is not a view

A view's `@Query` or `rememberQuery` asks the environment for a handle and
keeps it while the view lives. Any other code can make the same calls: a
service, a background refresh, a notification handler, a widget's
timeline. Nothing here is a second API. The environment has a call to
commit data, a handle to read it, and a retention to keep it. A view's
storage is made of the same three.

What does not change outside a view is that an operation is compiled,
never parsed at run time, and that reads run on the main actor in Swift
and on the store's thread in Kotlin.

## Where the GraphQL lives

`@Query("…")` in Swift is a view's storage, so code that is not a view
keeps its operations in a `.graphql` file in the target. The build plugin
compiles them with the target's Swift sources into the same operation
types. In Kotlin, `@Query` is a marker the compiler reads the text from.
It can sit on the function that sends the operation, as the GitHub
sample's `Environment.refreshRows` does, or the operation can go in a
`.graphql` document the Gradle task reads.

## Which call

| To | Swift | Kotlin |
|---|---|---|
| put an operation's data in the store, for whatever reads it | `try await environment.fetch(Q(...))` | `environment.fetch(Q(...))`, a `suspend` function |
| read what the store holds, with no request | `environment.handle(for: Q(...), fetchPolicy: .storeOnly).phase` | `environment.handle(Q(...), FetchPolicy.STORE_ONLY).phase` |
| keep the data and follow its changes | `handle(for:)`, `retain()`, and `Observations` over what it reads | `handle(...)`, `retain()`, and `snapshotFlow` over what it reads |
| write | `try await environment.mutate(M(...), optimistic:)`, which returns the data | `environment.mutate(M(...), optimistic)`, which returns the data |

## Read once

`fetch` always asks the network. It ingests the response off the main
actor, commits it, and returns nothing. The commit makes the operation's
root, and a root that nothing retains waits in the store's release
buffer, ten roots deep by default. A `storeOnly` handle then reads that
root without sending a request:

```swift
@MainActor
func characterName(id: String, in environment: Environment) async throws -> String? {
    try await environment.fetch(CharacterQuery(id: id))
    let handle = environment.handle(for: CharacterQuery(id: id), fetchPolicy: .storeOnly)
    guard case .ready(let data) = handle.phase else { return nil }
    return data.character?.name
}
```

```kotlin
// Called on the main dispatcher, the store's thread.
suspend fun Environment.characterName(id: String): String? {
    fetch(CharacterQuery(id = id))
    val phase = handle(CharacterQuery(id = id), FetchPolicy.STORE_ONLY).phase
    return (phase as? Phase.Ready)?.data?.character?.name
}
```

Read the values out when the call returns. A lens is a view onto records,
not a copy of them, and the records stay only while some root reaches
them. Once enough other roots are released after this one, the buffer
lets it go and the collector may reclaim its records. A lens held past
that point reads only what other roots keep, so code that holds data
longer retains it, as the next section shows.

The same `storeOnly` handle, with nothing fetched first, is an offline
read. When the store cannot answer, its phase is `.failed(MissingDataError)`
and no request is sent.

## Keep and follow

A service that lives longer than one call holds the handle and its
retention in properties, as a view's storage does. The default policy,
`storeOrNetwork`, sends a request only when the store cannot answer or
the data is stale, and the data stays while the retention lives. The
service reads the phase where it needs it, or observes what it reads: in
Swift through `Observations`, over a lens's fields and the handle's
phase, both `@Observable`, and in Kotlin through `snapshotFlow`, over the
same values as snapshot state. The compiled shapes are in three other
recipes:

- [derived state outside views](derived-state.md): a model that is not a
  view, in Swift and Kotlin;
- [UIKit and AppKit](uikit.md): a controller;
- [views and view models](views.md): a Kotlin model with no composition.

`refetch()` on the handle fetches again and waits for the result, keeping
the earlier data visible. `environment.invalidate()` marks every handle's
data stale, and `environment.revalidate()` refetches what is stale or
failed. All three work the same whether a view or a service holds the
handle.

## Write

`mutate` returns the mutation's data directly, so a service that writes
needs no handle. The payload stays readable until `releaseBufferSize`
completions of other operation values follow it. An optimistic response
shows in the turn of the call, wherever the caller is.

## Why no `fetchQuery` returns data

Relay's `fetchQuery` does not retain what it fetched either. Its
documentation sends code that wants the data kept to `environment.retain()`
on the query. Baton makes the same split: `fetch` commits, a handle
reads, and a retention keeps. If `fetch` returned a lens, the caller
would hold a value whose records nothing keeps alive.

## Off the main actor

A service running elsewhere hops to read. In Swift the environment and its
handles are `@MainActor`, so a caller off the main actor awaits each call
there. In Kotlin, the environment's `suspend` calls run on its main
dispatcher from whatever thread calls them, and a phase or a lens is read
on that dispatcher. The request and the ingest already run off the main
actor or the store's thread, and only the commit and the read run on it.

`OutsideViewsTests`, under `swift/Tests/BatonTests` and
`kotlin/baton/src/jvmTest`, prove what this page says on both runtimes.
