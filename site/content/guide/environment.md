# The environment

One environment per session: the store, the transport that fills it, the image on disk, the log. It is the one door everything from outside comes through, a server's response, an optimistic layer, a payload committed by hand, and the one thing an app ends at sign-out. This chapter is what it is made of and what it does.

## Making one

```swift tab
let environment = Baton.Environment(
    transport: URLSessionTransport(url: api, credentials: { ["Authorization": "Bearer \(token)"] }),
    store: Store(persistence: Persistence(name: "App", version: Types.schemaDigest))
)
```

```kotlin tab
val environment = Environment(
    HttpTransport(api, credentials = { mapOf("Authorization" to "Bearer $token") }),
    store = Store(persistence = Persistence.named("App", version = Types.schemaDigest, directory = cacheDir.path)),
)
```

Injected once at the root, `.environment(\.baton, environment)` in SwiftUI and `CompositionLocalProvider(LocalBaton provides environment)` in Compose, and every `@Query`, `@Mutation` and `@Subscription` below finds it. A view outside every environment reads as failed with an error that says so; nothing stands in for a missing environment.

## The transport has one verb

A transport takes a request and yields a stream of payloads: one for a query or a mutation, the parts of an incremental response, the events of a subscription. A request says its kind, so a wrapper never retries a mutation a server may have received, and carries the operation's document, text or id. One function, the encoding, turns a request into the JSON a server receives; a server with another convention replaces the function and keeps the transport.

The built-in transports are the platform's: `URLSessionTransport` and `GraphQLTransportWebSocket` in Swift; `HttpTransport` over `java.net` and `GraphQLTransportWebSocket` over the JVM's socket in Kotlin, with `OkHttpTransport` and `OkHttpWebSocketClient` in the `baton-okhttp` edge for an app that has an OkHttp client. All read credentials per attempt from a function, so a rotated token reaches the next request without a new environment.

{{script transport steps=1,2,4,6 | What a transport is handed, compared byte for byte: the standard encoding of a request, with `operationName`, `variables` and the text, or `documentId` under `persistConfig`. An enum variable is sent as its text, an input object as its fields, a nullable variable left unset is absent.}}

What a production endpoint needs beyond that, one replay of an authorization challenge, a bounded retry with backoff over the failures a retry can mend, a deadline across the attempts, is a transport that wraps a transport, written once around the one verb, and owned by the app. [The exchange](../../recipes/exchange/) walks through the one the GitHub samples send through, in both languages.

## The session

An environment pairs a store with the transport that fills it and replaces neither. A sign-in makes one; a sign-out ends it; which one is current is the app's state. Ending it cancels every fetch and stream it started, drops the roots, clears every record and closes the image, giving its file back. A response that lands later reaches neither memory nor the image; a handle still held reads as gone; every later call fails with the same error.

{{script end | The specification's end script: handles attached, a layer applied, the environment ended, and everything after it refused.}}

The order of a sign-out is the app's: end the environment, remove the image, forget the credential last.

```swift tab
await environment.end()
environment.store.persistence?.removeAll()
environment = makeEnvironment()
```

```kotlin tab
environment.end()
environment.store.persistence?.removeAll()
token = null
```

## Activity

The environment has an active flag the app sets from its lifecycle: false when the app goes to the background, true on its return, with `revalidate()` beside it to refetch what went stale meanwhile. While inactive, every retained subscription is parked and resumed on the return. In Swift it follows the scene phase; on Android the sample's `Activation` observes the process lifecycle.

## The log

The environment calls its log with each event of its work: a fetch started, completed with its duration or failed with its failure's kind; a commit with its kind and the count of slots it changed; a field error no `@catch` handled, by operation and path; the image opened, written or failed; and the missing-data cases, each by type and field name. Every event is value-free, a set of names and counts, never a record, a value or a response body, so an app routes it to its logging and metrics without logging anything a user typed.

{{script events steps=1,2,3,4,7,8 | What the specification requires the log to say for a commit, a fetch that fails by the transport and by a request error, a response whose field error no `@catch` handles, and an optimistic layer applied and resolved.}}

In Swift a debug build prints the missing-data events until a log is set; in Kotlin an environment made with `debug = true` does. A test sets none, or collects them and asserts on a name.

## Failures say their kind

A fetch or a stream that did not deliver fails in one of a closed set of kinds: the transport's, carrying what the transport threw unchanged; a request error, the server's errors with no data; a malformed response; the environment's, when nothing could send the request, because it is gone or has no subscription transport. A view branches on the kind, and an app's retry policy lives in its exchange, not in the view.

## A store without a server

A transport is a protocol with one verb, so a preview, a test and a benchmark each get a real store the way an app does, and never a mock of Baton's types: `SilentTransport` never answers, for a first body with no network behind it; `RecordedTransport` answers by operation name from recorded responses and keeps the requests it was sent; `ScriptedTransport` holds a mutation until the test replies or refuses, so the window between an optimistic apply and the server's answer is observable, and drives a subscription's events by hand.

```swift tab
let transport = ScriptedTransport([CharacterQuery.name: fixture("character-1")])
let environment = Environment(transport: transport, subscriptions: transport)
let task = Task { try await environment.mutate(SetFavorite(id: "1", favorite: true), optimistic: optimistic.payload) }
await wait(until: { transport.held.count == 1 })
transport.held[0].respond(fixture("set-favorite-1"))
```

```kotlin tab
val transport = ScriptedTransport(mapOf(CharacterQuery.name to fixture("character-1")))
val environment = Environment(transport, subscriptions = transport)
val job = launch { environment.mutate(SetFavorite(id = "1", favorite = true), optimistic.payload) }
wait(until = { transport.held.size == 1 })
transport.held.single().respond(fixture("set-favorite-1"))
```

They live in `BatonTesting` and `baton-testing`, which an app's tests import and its shipping binary does not. [Previews and tests](../../recipes/testing/) is the catalogue, and `commitPayload` is the way a preview's fixture becomes a store.

## Outside a view

A UIKit or AppKit controller, a Kotlin view model, a service: each asks the environment for a handle, holds the retention that keeps the handle's data alive, and reads what it shows. `environment.handle(for:)` in Swift and `environment.handle(operation)` in Kotlin resolve an operation value outside any view; `environment.fetch`, `mutate`, `preload` and `commitPayload` are the calls that need no view at all. [UIKit and AppKit](../../recipes/uikit/), [Views and view models](../../recipes/views/) and [Derived state](../../recipes/derived-state/) are the three recipes.
