# A fast stream, paced

A stream of quotes, presence flags or sensor readings can tick faster than
any screen redraws, across more keys than any screen shows. Its values
belong in the records the server's queries read, so one lens reads both,
and [a backend that is not GraphQL](another-backend.md) shows the two roads
there. This page is the shape for the fast case: what a tick costs, why the
app paces and the runtime does not, and the pacer, in Swift and then in
Kotlin. Nothing here is a new API.

Every number on this page is the Swift runtime's on the bench machine, an
Apple M1 Pro, quoted from
[the bench entry of 2026-11-23](../../BENCHMARKS.md#unreleased-a-feeds-ticks-through-the-two-doors--2026-11-23)
and rounded as it rounds them. The Kotlin runtime was not benched, and
neither was a phone; measure the app's own shape on its own device.

## Which shape at which rate

The main thread's time a second, in ms/s, through each shape. A tenth of a
frame per frame is 100 ms/s at 60 Hz and at 120 Hz.

| Shape | 100 ticks a second over 10 keys | 1,000 ticks a second over 100 keys |
|---|---|---|
| `commitPayload` per tick, a root per key | 15.8 | 405.4 (548.1 in the later run) |
| The same, every key's root held by a handle | not run | 89.0 (100.4 in the later run) |
| A subscription per key, answered by the app's transport | 20.5 | 120.6 |
| Paced, 30 commits a second, as drained | 27.9 | 32.2 |
| Paced, 30 commits a second, every known key listed | 5.3 | 10.9 |
| Paced, 60 commits a second, every known key listed | 8.2 | 15.6 |

The per-tick and subscription rows are from the entry's first run, taken
under another project's load; the paced rows and the figures in
parentheses from [its later, quieter run](../../BENCHMARKS.md#the-paced-shape).
The paced shape's cost follows the commits it makes, not the ticks it is
given; at 100 ticks a second over 10 keys, as drained, it costs more than a
commit per tick, for the reason in [every known key, listed](#every-known-key-listed).

## What a tick costs

Delivery is not the limit. In every run, through either door, the last
tick committed within 7.1 ms of its send and the image's writer emptied its
queue within 7.3 ms of the last tick. The limit is the main thread's share
of each frame, and it crosses a tenth of a frame at 1,000 ticks a second:
through `commitPayload` over 1 key and over 100, and through a subscription
over every key count. At 100 ticks a second the highest is 79 ms/s.

The cost is per commit far more than per value. A later tick called back
to back costs the main thread 13 µs; the same tick arriving alone at a
sustained rate costs it 89 µs or more at 1,000 a second and 158 µs or more
at 100. One payload carrying 100 keys costs the main thread 176 µs back to
back, about what one or two ticks cost at a sustained rate.

So the runtime neither batches nor drops ticks, and there is no
`commitPayloads`: a merge in the runtime would have to know that a newer
value for a key supersedes an older one, and only the app knows that. The
app paces.

## The shape

1. **Decode off the main actor.** The wire format is the feed client's,
   and it decodes on its own thread or task; the door's ingest runs off the
   main actor too. Only the commit runs on it.
2. **Keep the newest pending value per key.** A tick for a key that has
   not been committed yet replaces the pending one.
3. **Once per interval, commit one payload** carrying every pending key,
   through one operation with one root.

The operation is a client-only query over a client list field that returns
the server's own type. The list is the client's, declared under
`schemaExtensions`; the entities it links are the server's `Quote`
records:

```graphql
# client.graphql, listed under schemaExtensions
extend type Query {
  liveQuotes: [Quote]
}
```

```graphql
query LiveQuotes @raw_response_type {
  liveQuotes { id price updatedAt }
}
```

```json
{
  "schemaDir": "schema",
  "schemaExtensions": ["client.graphql"],
  "identity": { "default": ["id"] },
  "transient": { "fields": ["Query.liveQuotes"] }
}
```

The query is never sent: its handle attaches from the store whatever the
policy, and no fetch is ever made for it. Each quote in a payload merges
by its identity into the record the server's queries read: the fields the
payload gives are written, and a field it does not give, a quote's `name`,
stays as the server wrote it. `transient` names the root field, so the
list's cell and the operation's fetch stamp never reach the image, while
the quotes' records do; with the root field not transient the bench wrote
1.47 MB a second against 1.21.

`updatedAt` is the tick's own time, a field of the entity. A lens reads it
as it reads the price, so a row shows the age of its own value, not the
age of the commit that carried it.

## The pacer, in Swift

```swift
struct QuoteTick: Sendable {
    let symbol: String
    let price: Double
    let time: String
}

actor QuotePacer {
    private var pending: [String: QuoteTick] = [:]

    func offer(_ tick: QuoteTick) {
        pending[tick.symbol] = tick
    }

    func drain() -> [QuoteTick] {
        defer { pending.removeAll(keepingCapacity: true) }
        return Array(pending.values)
    }
}

func commitPaced(_ pacer: QuotePacer, to environment: Environment, every interval: Duration, clock: some Clock<Duration>) async {
    while !Task.isCancelled {
        do { try await clock.sleep(for: interval) } catch { return }
        let pending = await pacer.drain()
        if pending.isEmpty { continue }
        let response = LiveQuotes.RawResponse(liveQuotes: pending.map { .init(id: $0.symbol, price: $0.price, updatedAt: $0.time) })
        try? await environment.commitPayload(LiveQuotes(), response.payload)
    }
}
```

The service runs two loops off the main actor, the feed's and the
pacer's, and holds the list's root so the release buffer never pushes it
out:

```swift
let pacer = QuotePacer()
let live = environment.handle(for: LiveQuotes())
let retention = live.retain()
let feeding = Task.detached {
    for try await tick in feed.ticks() { await pacer.offer(tick) }
}
let pacing = Task.detached {
    await commitPaced(pacer, to: environment, every: .milliseconds(33), clock: ContinuousClock())
}
```

`feed` is the app's own client, whose `ticks()` decodes each message off
the main actor. An interval with no tick commits nothing. The service sets
this up from the main actor, since `Environment` and its handles are
`@MainActor`; the two detached tasks capture the environment, the pacer
and the feed, and `commitPaced` runs off the main actor, only the commit
hopping to it. It ends by cancelling both tasks and releasing the
retention.

## The pacer, in Kotlin

The pacer is a map under a lock, since the feed's thread offers and the
service's coroutine drains:

```kotlin
class QuoteTick(val symbol: String, val price: Double, val time: String)

class QuotePacer {
    private val pending = HashMap<String, QuoteTick>()

    fun offer(tick: QuoteTick) = synchronized(pending) { pending[tick.symbol] = tick }

    fun drain(): List<QuoteTick> = synchronized(pending) { pending.values.toList().also { pending.clear() } }
}

suspend fun commitPaced(pacer: QuotePacer, environment: Environment, interval: Duration) {
    while (true) {
        delay(interval)
        val pending = pacer.drain()
        if (pending.isEmpty()) continue
        val response = LiveQuotes.RawResponse(liveQuotes = pending.map { LiveQuotes.RawResponse.LiveQuotes(id = it.symbol, price = it.price, updatedAt = it.time) })
        environment.commitPayload(LiveQuotes(), response.payload)
    }
}
```

The service launches it in a scope of its own, off the main dispatcher,
and holds the list's root while it paces:

```kotlin
val pacer = QuotePacer()
val hold = environment.handle(LiveQuotes()).retain()
val feeding = scope.launch(Dispatchers.Default) { feed.ticks().collect { pacer.offer(it) } }
val pacing = scope.launch(Dispatchers.Default) { commitPaced(pacer, environment, 33.milliseconds) }
// when it stops:
feeding.cancel()
pacing.cancel()
hold.release()
```

`commitPayload` runs its commit on the environment's main dispatcher
whatever thread calls it.

## Every known key, listed

A drain carries the keys that ticked since the last one, so each commit's
list holds different keys from the last one's. A commit that drops a link
schedules a collection, since the record the link pointed at may now be
unreachable, and a collection is a mark of the whole store on the main
actor: one per commit, about 0.7 ms each at 30 and at 60 commits a second.

The refinement lists every known key in every commit, in the order each
was first seen, a key that did not tick by its `id` alone. The list then
only grows, and a field the payload leaves out is left untouched in the
store, so no link is dropped and no collection runs. At 1,000 ticks a
second over 100 keys:

| Commits a second | As drained, ms/s | Every known key listed, ms/s |
|---|---|---|
| 30 | 32.2 | 10.9 |
| 60 | 55.6 | 15.6 |

In Swift, the pacer keeps the order and the drain returns every key with
its pending tick, if any:

```swift
actor ListingPacer {
    private var known: [String] = []
    private var seen: Set<String> = []
    private var pending: [String: QuoteTick] = [:]

    func offer(_ tick: QuoteTick) {
        if seen.insert(tick.symbol).inserted { known.append(tick.symbol) }
        pending[tick.symbol] = tick
    }

    func drain() -> [(symbol: String, tick: QuoteTick?)] {
        if pending.isEmpty { return [] }
        defer { pending.removeAll(keepingCapacity: true) }
        return known.map { ($0, pending[$0]) }
    }
}
```

and the loop, `commitPaced` with this body, writes a key that did not
tick by its id alone:

```swift
let listed = await pacer.drain()
if listed.isEmpty { continue }
let response = LiveQuotes.RawResponse(liveQuotes: listed.map { symbol, tick in
    guard let tick else { return .init(id: symbol) }
    return .init(id: symbol, price: tick.price, updatedAt: tick.time)
})
try? await environment.commitPayload(LiveQuotes(), response.payload)
```

In Kotlin a `LinkedHashMap` keeps the order a key was first put in:

```kotlin
class ListingPacer {
    private val known = LinkedHashMap<String, QuoteTick?>()
    private var ticked = false

    fun offer(tick: QuoteTick) = synchronized(known) {
        known[tick.symbol] = tick
        ticked = true
    }

    fun drain(): List<Pair<String, QuoteTick?>> = synchronized(known) {
        if (!ticked) return emptyList()
        ticked = false
        known.entries.map { it.key to it.value }.also { known.replaceAll { _, _ -> null } }
    }
}
```

```kotlin
val listed = pacer.drain()
if (listed.isEmpty()) continue
val response = LiveQuotes.RawResponse(liveQuotes = listed.map { (symbol, tick) ->
    if (tick == null) LiveQuotes.RawResponse.LiveQuotes(id = symbol)
    else LiveQuotes.RawResponse.LiveQuotes(id = symbol, price = tick.price, updatedAt = tick.time)
})
environment.commitPayload(LiveQuotes(), response.payload)
```

It stops paying where the payload grows: every commit carries every known
key, so its ingest and its commit grow with the keys the app has seen, not
with those that ticked. For a set of keys that keeps growing, or one far
larger than what ticks in an interval, start a new list now and then; that
commit drops links and pays one collection.

## The road per tick

Committing each tick through an operation with a variable per key, the
server's `quote(symbol:)`, makes a root per key. A root nothing holds waits
in the release buffer, ten deep by default; past ten keys every tick
pushes one out, and a collection follows. Over 100 keys a burst of 1,000
ticks cost the main thread 160 ms with no root held against 17.9 ms with
every root held, and the sustained run 405 ms/s at 1,000 ticks a second
against 89. That road is right for a handful of keys, a REST response or a
push. For more, hold each key's root, as a view would, through a handle
and its retention ([outside views](outside-views.md) says how a service
holds one), or use the paced shape above.

Both costs, the root pushed out and the link dropped, are the store's
collection, and how eagerly the store collects is its own schedule, set by
a bench. They describe today's schedule, not the contract.

## Reading a quote the server never answered

A quote the feed wrote and the server never answered has a record and no
`quote(symbol:)` root cell, so the server's query does not reach it until
it is fetched. A `lookups` entry in `baton.json` for that root field,
`{ "field": "Query.quote", "type": "Quote", "argument": "symbol" }`, makes
the availability check bind the field to the record
([the decision](../decisions/lookups-bind-in-the-check.md)).

## While the app is inactive

`Environment.isActive` parks subscriptions and is read by streams alone;
`commitPayload` commits whether the app is active or not. The pacer is the
app's, so the app pauses it with its scene: it cancels the pacing loop,
closes the feed or stops offering to the pacer, and drops what arrives
while paused. On return it refetches the baseline, `refetch()` on the
handle the service holds for the server's query, and starts the loop
again; [outside views](outside-views.md) names the calls.

## The image

The image is written behind every commit, so a paced commit also bounds
the writer's work. The paced shape wrote 1.0 to 1.3 MB a second where a
commit per tick wrote 8.7 to 13.1, and the transient root field keeps the
list out of the image while the quotes it links are written.

## The lag

A committed value waits for its interval: at the median half the interval,
and at the worst the interval plus the commit. The bench measured 51 ms at
10 commits a second, 15 to 17 ms at 30, and 7 to 9 ms at 60. At 10 a
second about 1.6 % of the ticks over 100 keys were replaced in the pacer
before a drain, and none at 30 or 60.

## When a view holds the stream

A stream a view holds, a quote while its row is on screen, takes the other
road: a subscription the app's transport answers
([a backend that is not GraphQL](another-backend.md)), whose root the
handle holds, so no root is pushed out and no collection follows. An
event costs the main thread 30.4 µs from the feed's yield to the commit,
against 13 µs for a tick through `commitPayload` back to back, and the
sustained cost is 20 to 24 ms/s at 100 events a second over any key
count, and 120.6 to 142.3 at 1,000. The subscription fits the few keys a screen
shows; the paced service fits a feed over many keys, or one the app keeps
open whatever the views show.

## What the tests prove

`PacedCommitTests`, under `swift/Tests/BatonFeedTests` and
`kotlin/baton/src/jvmTest/kotlin/baton/feed`, prove what this page says on
both runtimes: the list query compiles as client-only and is never sent;
one payload merges each quote into the record the server's query reads and
leaves its other fields; the pacer commits the newest tick of each key once
per interval and nothing for an interval without ticks; with the image
attached the quotes' records are written and the transient list's cell is
not; the list query parks one root and runs no collection where a root per
key runs one a commit past ten; a list that drops a key schedules a
collection where one that lists every known key schedules none; the
listing pacer, across intervals, commits a list that only grows and runs
no collection; the service's wiring runs and ends; and `commitPayload`
commits while the environment is inactive, and the held query's
`refetch()` fetches the baseline again.
