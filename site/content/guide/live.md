# Live data

Two ways data arrives after the first response: a subscription, a stream of events the server pushes, and a deferred fragment, a part of a response the server sends later. Both go through the same door as a query's response, into the same records, so a view that reads a record it names updates like after any commit.

## A subscription is a stream of events into the store

A subscription is the third kind of operation, declared like a query and resolved in a view. Its handle is open while the view lives and closed when it goes. Each event is a payload in the operation's shape, normalized at the subscription root and committed; an edge directive on the event's payload appends it to a connection, so a live list grows without a refetch.

{{host live Live.swift | A notes list with a subscription for new notes. The event's edge is appended to the connection the list's lens named, exactly as a mutation's would be.}}

{{operation live NoteAdded | What the server receives for the subscription: the operation's text, with the edge directive left out, since it is the client's business.}}

## The stream as a value

The handle reads the stream as a value, never awaited: `idle`, parked while the app is inactive; `connecting` until the first event; `open`; `waiting` to reconnect after a failure, by a fixed backoff, a step doubling from one second to thirty and jittered, reset by an event; or `ended`, by the server's completion, by a request error the server would repeat, or by the environment's end. `resumptions` counts the reopenings, since events may have been missed across each; an owner that cares observes it and refetches its baseline. `retry()` opens a waiting or ended stream at once.

{{script subscriptions | The specification's subscription script: a stream connecting, open on its first event, ended by a request error, parked while the app is inactive and resumed when it returns, completed by the server, and waiting after a transport failure.}}

The environment's active flag is the app's to set, from the scene phase in Swift and from the process lifecycle on Android; while it is false every retained subscription is parked, and a `revalidate()` on the return refetches what went stale meanwhile. The Android sample's `Activation` and the UIKit recipe's lifecycle section are the two spellings.

## The transport underneath

Subscriptions travel through the environment's subscription transport, which is any transport with the one verb: the socket transport speaks `graphql-transport-ws`, and the HTTP transport reads `text/event-stream` for `graphql-sse` in its distinct-connections mode, so a server that streams over HTTP needs no socket at all. On Android the platform has no WebSocket client, so the socket is the app's own, through the `baton-okhttp` edge or any client that implements the protocol's few calls.

```swift tab
Environment(
    transport: URLSessionTransport(url: api, credentials: credentials),
    subscriptions: GraphQLTransportWebSocket(url: socket, credentials: credentials)
)
```

```kotlin tab
Environment(
    HttpTransport(api, credentials = credentials),
    subscriptions = GraphQLTransportWebSocket(socket, client = OkHttpWebSocketClient(okHttp), credentials = credentials),
)
```

## A part that arrives later: `@defer`

A spread marked `@defer` is a part the server may deliver in a later part of the same response. The spread's accessor is optional and nil until the fragment's fields are present, and the rest of the operation renders meanwhile; the availability check does not wait for the deferred part, and a part the store holds only half is cleared and fetched rather than read as empty.

{{host live CharacterScreen | A screen that renders the name at once and the notes when their part lands. `isPresent`, generated beside the accessor, says whether it has.}}

The built-in HTTP transport reads `multipart/mixed` for the parts, and the environment assembles each at the record its path names. A deferred part the server addresses to a place the store does not have is dropped and logged, never applied somewhere else.

## What a view does not do

A view never awaits an event, never holds a socket, and never merges a stream into its own state. It reads the record the event changed, as it reads any record, and the stream's state when it wants to show a dot. The tests drive a subscription by hand with `ScriptedTransport`, delivering, completing or failing events; [Previews and tests](../../recipes/testing/) shows how.
