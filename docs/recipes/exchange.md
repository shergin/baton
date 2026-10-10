# The exchange: a challenge, a retry and a deadline over one verb

Baton's transport has one verb, `send`: a request yields a stream of
payloads. The built-in transports read credentials per attempt from a
function, so a rotated token reaches the next request without a new
environment. What a production endpoint needs beyond that is a composition
of that verb, and compositions ship as examples, not as library types: a
transport that wraps a transport is written once, around one method, and
the app owns it and its numbers. Two copies are compiled in this
repository, one per runtime, and this page walks through them:
[`examples/Exchange/Exchange.swift`](../../examples/Exchange/Exchange.swift),
which the Swift GitHub sample sends through, and
[`kotlin/samples/exchange/src/commonMain/kotlin/baton/exchange/Exchange.kt`](../../kotlin/samples/exchange/src/commonMain/kotlin/baton/exchange/Exchange.kt),
which the Kotlin one sends through. Copy the one for your runtime, and
change the numbers to the endpoint's.

## What it does, in order

1. **Credentials per attempt** are the base transport's: its `credentials`
   function is read on every attempt, so a token renewed between two
   attempts reaches the second. The exchange adds no header of its own.
2. **One replay of a challenge.** A 401 calls `challenged()` once per
   request, the place to renew the token, and sends the request again. A
   second 401 fails the request. A 401 was refused before execution, so
   the replay applies to a mutation as well.
3. **A mutation is never sent twice** otherwise. The server may have
   received it; a second send would apply it again.
4. **A bounded retry with backoff** over the outcomes a retry can mend: a
   5xx status, or a connection that was lost or timed out. The wait doubles
   from the first step and is jittered. A 4xx other than 401, a request
   error (the server answered with errors) and a malformed response are not
   retried: they would repeat. In Swift a lost connection is the platform's
   `URLError`; in Kotlin the built-in transports report it as a
   `TransportError` of status 0 whose `cause` is the connection's own
   exception, and a status 0 with no cause, a request the transport could
   not make, is not retried either.
5. **A deadline spanning every attempt**, the waits included: a retry whose
   wait would pass it fails with the last error instead. The time one
   attempt may take is the session's own timeout.
6. **A stream that delivered is not sent again.** Once a payload reached the
   caller, a later failure ends the stream: a deferred response's remaining
   parts are not fetched twice, and a subscription reconnects by its
   handle's own rule, not here.

## Credentials stay with their host

Credentials belong to one endpoint. Keep them in the base transport whose
`url` is that endpoint, never in a wrapper that could be pointed elsewhere:
an `Exchange` over a `URLSessionTransport(url: api, credentials: token)`,
or over an `HttpTransport(api, credentials = token)`, sends the token to
`api` and nowhere else, because nothing but that transport reads the
function.

## Wiring

In Swift:

```swift
let api = URLSessionTransport(
    url: URL(string: "https://api.example.com/graphql")!,
    credentials: { ["Authorization": "Bearer \(await session.token())"] }
)
let environment = Environment(
    transport: Exchange(base: api, attempts: 3, deadline: .seconds(30)) {
        try await session.renew()
    },
    subscriptions: GraphQLTransportWebSocket(
        url: socketURL,
        credentials: { ["Authorization": "Bearer \(await session.token())"] }
    )
)
```

In Kotlin, the same shape over the runtime's `HttpTransport`; the GitHub
sample's `Main.kt` wires `Environment(Exchange(HttpTransport(url,
credentials = { mapOf("Authorization" to "Bearer $token") })), store = ...)`
with the defaults:

```kotlin
val api = HttpTransport(
    "https://api.example.com/graphql",
    credentials = { mapOf("Authorization" to "Bearer ${session.token()}") },
)
val environment = Environment(
    Exchange(api, attempts = 3, deadline = 30.seconds) { session.renew() },
    subscriptions = GraphQLTransportWebSocket(
        socketUrl,
        credentials = { mapOf("Authorization" to "Bearer ${session.token()}") },
    ),
)
```

A subscription sent through the exchange gets its retry too, until its
first event; after that the handle's reconnection takes over. A socket
transport renews its own connection, so it usually stands alone, as above.
In Kotlin the socket transport takes the client it opens sockets with: on
the JVM `GraphQLTransportWebSocket(url, credentials = ...)` picks the
JVM's own, and on Android, whose platform has none,
`GraphQLTransportWebSocket(url, credentials = ..., client =
OkHttpWebSocketClient(okHttp))` from `baton-okhttp`, beside an
`OkHttpTransport(okHttp, url)` for the queries, which the exchange wraps
the same way.

## The loop, in Kotlin

The Kotlin exchange is one `flow` around the base transport's `send`. The
flow is cold, so each collection is one exchange, and a consumer that goes
away cancels the attempt under it; the deadline is read off the monotonic
clock, and the waits are `delay`s. This is the compiled code:

```kotlin
override fun send(request: Request): Flow<ByteArray> = flow {
    val started = TimeSource.Monotonic.markNow()
    var replayed = false
    var retries = 0
    while (true) {
        var delivered = false
        try {
            base.send(request).collect { payload ->
                delivered = true
                emit(payload)
            }
            return@flow
        } catch (error: Throwable) {
            // The collector going away is not the attempt's failure.
            if (error is CancellationException) throw error
            // A stream that delivered is not sent again: the caller has
            // part of the answer, and a stream resumes nothing.
            if (delivered) throw error
            // A 401 was refused before execution, so even a mutation is
            // sent once more, with the renewed token.
            if (error is TransportError && error.statusCode == 401 && !replayed) {
                replayed = true
                challenged()
                continue
            }
            // A mutation is never sent twice: the server may have
            // received it.
            if (request.kind == OperationKind.MUTATION || !mends(error) || retries + 1 >= attempts) throw error
            // The wait doubles and is jittered; the deadline covers the
            // wait as well as the attempt.
            val pause = step * (1 shl minOf(retries, 10))
            val wait = pause / 2 + pause / 2 * Random.nextDouble()
            if (started.elapsedNow() + wait >= deadline) throw error
            delay(wait)
            retries += 1
        }
    }
}
```

Whether a failure is one a retry can mend is one function, which an app
with another transport, or another judgement, edits:

```kotlin
/**
 * Whether a retry may mend a failure: a 5xx status, or a connection
 * that was lost or timed out, which the transport reports as a
 * status 0 with the connection's failure as its cause. A 4xx other
 * than 401, a request error, a malformed response and a request the
 * transport could not make would repeat.
 */
fun mends(error: Throwable): Boolean {
    if (error !is TransportError) return false
    if (error.statusCode in 500..599) return true
    return error.statusCode == 0 && error.cause != null
}
```

The Swift exchange is the same loop over an `AsyncThrowingStream`, with
`Task.sleep` for the waits and `URLError`'s codes in `mends`.

## What the tests prove

The Swift package's tests (`ExchangeTests` under `swift/Tests/BatonTests`)
run the sample over a scripted transport: a 401 then a success is sent
twice and renews the token between; a 503 then a 200 is sent twice; a
deadline that expires during the backoff fails with the 503 and no wait; a
mutation refused with a 503 is sent once and fails; a query whose stream
delivered a payload before failing is not sent again; the credentials the
base transport reads change between two attempts; and a held mutation's
optimistic layer stays applied while a query beside it is retried.

The Kotlin runtime's JVM tests (`ExchangeTests` under
`kotlin/baton/src/jvmTest`) prove the same of the Kotlin exchange over
`baton-testing`'s `ScriptedTransport` and a loopback server: the replayed
challenge carries the renewed token; a second challenge fails; a 503 then
a 200 is sent twice; the attempts bound the sends; a deadline that expires
during the backoff fails at once; a mutation refused with a 503 is sent
once; a cancelled consumer ends the held attempt; an environment over an
exchange reads ready after a retry; and a held mutation's optimistic layer
stands through a retry beside it.
