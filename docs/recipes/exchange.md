# The exchange: a challenge, a retry and a deadline over one verb

Baton's transport has one verb, `send`: a request yields a stream of
payloads. The built-in transports read credentials per attempt from a
closure, so a rotated token reaches the next request without a new
environment. What a production endpoint needs beyond that is a composition
of that verb, and compositions ship as examples, not as library types: a
transport that wraps a transport is written once, around one method, and
the app owns it and its numbers. [`examples/Exchange/Exchange.swift`](../../examples/Exchange/Exchange.swift)
is the one this page walks through, and the one the GitHub sample sends
through. Copy it, and change the numbers to the endpoint's.

## What it does, in order

1. **Credentials per attempt** are the base transport's: its `credentials`
   closure is read on every attempt, so a token renewed between two
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
   retried: they would repeat.
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
an `Exchange` over a `URLSessionTransport(url: api, credentials: token)`
sends the token to `api` and nowhere else, because nothing but that
transport reads the closure.

## Wiring

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

A subscription sent through the exchange gets its retry too, until its
first event; after that the handle's reconnection takes over. A socket
transport renews its own connection, so it usually stands alone, as above.

## What the tests prove

The package's tests run the sample over a scripted transport: a 401 then a
success is sent twice and renews the token between; a 503 then a 200 is
sent twice; a deadline that expires during the backoff fails with the 503
and no wait; a mutation refused with a 503 is sent once and fails; a query
whose stream delivered a payload before failing is not sent again; the
credentials the base transport reads change between two attempts; and a
held mutation's optimistic layer stays applied while a query beside it is
retried.
