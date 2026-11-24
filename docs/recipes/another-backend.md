# A backend that is not GraphQL

Some data an app shows comes from beside its GraphQL server: a socket of
another protocol whose ticks update records, a REST endpoint, a push. That
data belongs in the store, keyed and merged with what the server sent, so
one lens reads both. Nothing here is a new API. The schema declares the
fields, an operation selects them, and the data reaches the store through
one of two roads Baton already has: the app's transport answering the
operation, or `commitPayload` from a service. This page is the
composition, in Swift and then in Kotlin.

## Which road

| The data | The road | What it gets |
|---|---|---|
| A stream a view holds: a quote while its row is on screen | A subscription the app's own transport answers | The handle's stream: reconnection by the fixed backoff, parking while the app is inactive, one handle for equal operation values, the events committed at the subscription root |
| A socket the app keeps open whether or not a view shows it, a REST response, a push | `commitPayload(operation, response.payload)` from a service | The door a fetch's response takes: the records merge, the edge directives apply, the image is written |

Both roads write the same records. A lens over `Quote` reads the price
whichever one wrote it.

## The schema file

The fields another backend answers are schema, not client schema: the
schema describes what the transport answers, and the app's transport
answers these. Put them in a file of their own beside the server's SDL,
and name the directory with Relay's `schemaDir` in place of `schema`:

```
schema/
  feed.graphql
  server.graphql
```

```json
{"schemaDir": "schema"}
```

```graphql
# schema/feed.graphql
extend type Subscription {
  quoteChanged(symbol: ID!): Quote!
}
```

The directory's `.graphql` files are the schema together, in name order.
An `extend` in a file of the schema adds server fields, so
`quoteChanged` is sent, waited for by the availability check and healed
like any field, and it may come before the type it extends:
`feed.graphql` sorts before `server.graphql` and still compiles. A type
the server lacks is declared in the same file. `Quote` here is the
server's own type, so the ticks merge into the records the server's
queries wrote.

Do not list the file under `schemaExtensions`. A client field is what no
transport is asked for, and a subscription of client fields alone is
refused at its name. The command-line form, `--schema` repeated or naming
a directory, and the build integrations' inputs are in
[the compiler's recipe](batonc.md), [Gradle](gradle.md) and
[Bazel](bazel.md).

## The operation

```graphql
subscription QuoteTicks($symbol: ID!) @raw_response_type {
  quoteChanged(symbol: $symbol) { id price updatedAt }
}
```

Relay's `@raw_response_type` nests `RawResponse` in the operation's
value: a typed builder of the response, one type per selection set, every
field an optional parameter, whose `payload` is the bytes the door takes.
The adapter from the other protocol writes the response through it, so
when the selection changes the adapter stops compiling, rather than
writing JSON that no longer matches. A view holds the subscription as it
holds any other: `@Subscription` in Swift, `rememberSubscription(...)` in
Kotlin.

## The transport

The environment's subscription transport is the app's: it answers the
feed's operation itself and sends every other request to the server's
socket. It routes by `Request.operationName`.

In Swift:

```swift
struct FeedTransport: Transport {
    let server: any Transport   // the GraphQL server's socket
    let feed: QuoteFeed         // the app's client for the other protocol

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        guard request.operationName == QuoteTicks.name,
              case .string(let symbol)? = request.variables["symbol"]
        else { return server.send(request) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await tick in feed.ticks(symbol: symbol) {
                        let response = QuoteTicks.RawResponse(quoteChanged: .init(id: symbol, price: tick.price, updatedAt: tick.time))
                        continuation.yield(response.payload.bytes)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

`QuoteFeed` is the app's own client: here its `ticks(symbol:)` returns an
`AsyncThrowingStream` of ticks, each with a `price` and a `time`. When the
handle is released, the stream ends, `onTermination` cancels the feed's
task, and nothing reopens it. An error the feed throws, of the app's own
type, is a transport failure to the handle: it waits by its backoff and
opens the stream again, as it does over a built-in transport. Only a
request error, `GraphQLErrors`, or an environment error ends the stream
for good. A feed that finishes is the server's completion, and the stream
stays ended until a retry.

In Kotlin, `send` returns a `Flow`, and `feed.ticks(symbol)` returns a
`Flow` of ticks; there is no task and no termination hook, since
cancelling the collection ends the feed's flow:

```kotlin
class FeedTransport(private val server: Transport, private val feed: QuoteFeed) : Transport {
    override fun send(request: Request): Flow<ByteArray> {
        val symbol = (request.variables["symbol"] as? Variable.String)?.value
        if (request.operationName != QuoteTicks.name || symbol == null) return server.send(request)
        return feed.ticks(symbol).map { tick ->
            QuoteTicks.RawResponse(quoteChanged = QuoteTicks.RawResponse.QuoteChanged(id = symbol, price = tick.price, updatedAt = tick.time)).payload.bytes
        }
    }
}
```

## The environment

The feed's transport wraps the server's socket as the environment's
subscription transport, over a `feed` the app already has. Queries and
mutations go to the server as before. `subscriptions` does not fall back
to `transport`: a subscription in an environment without a subscription
transport ends with the environment error for the missing one.

```swift
let feed: QuoteFeed
let api = URLSessionTransport(
    url: URL(string: "https://api.example.com/graphql")!,
    credentials: { ["Authorization": "Bearer \(await session.token())"] }
)
let environment = Environment(
    transport: api,
    subscriptions: FeedTransport(
        server: GraphQLTransportWebSocket(
            url: socketURL,
            credentials: { ["Authorization": "Bearer \(await session.token())"] }
        ),
        feed: feed
    )
)
```

```kotlin
val feed: QuoteFeed
val api = HttpTransport(
    "https://api.example.com/graphql",
    credentials = { mapOf("Authorization" to "Bearer ${session.token()}") },
)
val environment = Environment(
    api,
    subscriptions = FeedTransport(
        GraphQLTransportWebSocket(
            socketUrl,
            credentials = { mapOf("Authorization" to "Bearer ${session.token()}") },
        ),
        feed,
    ),
)
```

An app that also routes queries to another backend, a REST endpoint,
wraps `transport` the same way: it answers a query by its name with one
payload, the endpoint's answer written through the query's
`RawResponse`, and sends every other request to the server.

## From a service

A socket the app keeps open whatever the views show is the service's,
not a transport's. The service writes each message through the raw
response of an operation that selects what the message carries, here the
server's query a screen reads a quote by, and commits it:

```graphql
query QuoteQuery($symbol: ID!) @raw_response_type {
  quote(symbol: $symbol) { id price }
}
```

```swift
for try await tick in feed.ticks(symbol: symbol) {
    try await environment.commitPayload(QuoteQuery(symbol: symbol), QuoteQuery.RawResponse(quote: .init(id: symbol, price: tick.price)).payload)
}
```

In Kotlin `commitPayload` is a `suspend` function:

```kotlin
feed.ticks(symbol).collect { tick ->
    environment.commitPayload(QuoteQuery(symbol = symbol), QuoteQuery.RawResponse(quote = QuoteQuery.RawResponse.Quote(id = symbol, price = tick.price)).payload)
}
```

The payload is committed at the root of the operation's kind, and the
`Quote` it carries merges into its record: `price` is written, and the
record's other fields stay as they were, so every lens over that quote
reads the new price. A push or a REST response the app fetches itself
goes the same way. A stream over many keys, or faster than a screen
redraws, is paced and committed in one payload per interval:
[a fast stream, paced](stream.md).
[Outside views](outside-views.md) is the rest of what a service does with
the environment.

## The limits

- **One operation, one transport.** The app's transport answers an
  operation whole, or sends it on whole; nothing splits one operation
  between backends, and the library ships no router. A field the feed
  adds to a server type is selected only by operations the feed answers:
  a query sent to the server that selects it is one the server cannot
  answer.
- **The transport gives what the operation selects.** The feed's fields
  are server fields, so what a payload leaves out reads as missing, as in
  a partial response, and the availability check waits for it. Write every
  selected field, the key above all, since the record is keyed by it.
- **A builder cannot write a null.** A parameter left nil is absent from
  the payload, not null, as in an `OptimisticResponse`. A message that
  must null a field is a payload written as JSON, `Payload(json:)` in
  Swift and `Payload(json)` in Kotlin.
- **Persisted documents.** Under `persistConfig` the feed's operation
  takes an id and lands in the persisted documents file like any other,
  and its request carries the id, not the text; the transport routes by
  name and never reads either. The app's registration step leaves the
  operation out of what it registers with the server.
- **Pacing.** A stream that ticks faster than a screen needs commits every
  tick. The pacing of a fast stream has its own recipe,
  [a fast stream, paced](stream.md).

The decisions are
[the schema is what the transport answers](../decisions/the-schema-is-what-the-transport-answers.md)
and [a raw response is asked for](../decisions/a-raw-response-is-asked-for.md).
