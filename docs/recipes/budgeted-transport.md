# A budgeted transport: a queue, a meter and an outage over one verb

Some public APIs ration requests. AniList's allows 30 a minute per IP
address, shared with every other client on the user's network. Past that
it times the address out for a minute, and answers 429 with a
`Retry-After` header and nothing else, sometimes with an HTML body from
Cloudflare. During an outage it answers 403, with a body that says the API
"has been temporarily disabled". An app for such an API wants five things:
one request in flight, the user's write ahead of a refresh ahead of a page
being browsed to, a meter that stays under the server's limit, a pause
after a refusal, and an outage shown calmly rather than as an error.

None of it is a new concept. It is a transport that wraps a transport,
around the one verb, as [the exchange](exchange.md) is. The app owns the
wrapper and the numbers, and the library ships neither: a composition is
an example, and shipped wrappers were refused on
[#19](https://github.com/shergin/baton/issues/19). The code below is the
whole budget in both runtimes. Copy the one for your runtime, and change
the numbers to the endpoint's.

## Where it sits

The queue and the meter sit in the wrapper, the one place every request
passes, whichever view, model or refresh sent it. The built-in transports
know an endpoint, not its budget. A view knows its own request, not the
others in flight.

The budget sits closest to the endpoint, under the exchange, so that every
send the exchange makes, a retry included, waits its turn and counts
against the meter. The exchange retries neither a 429 nor a 403, since
neither is a 5xx or a lost connection, so the budget's own rules decide
both.

Subscriptions do not pass through it. The environment sends a
subscription through its `subscriptions:` transport, and an open stream
would hold the one turn for as long as it is open.

The budget lives as long as its environment. A sign-out ends both, and
the next account's budget starts with an empty meter. The pause after a
429 covers the minute that overlaps.

## What it does, in order

1. **One request in flight.** A request waits for its turn, and the turn
   passes to the most urgent waiting request, the earliest among equals.
2. **Priorities the app decides.** A `Request` carries its kind and its
   operation's name, and the app maps them to a write, a refresh or a
   browse page. By default a mutation is a write and anything else is a
   refresh.
3. **A meter under the server's limit.** No more sends in any sixty
   seconds than `perMinute`. Twenty-five leaves AniList's thirty some room
   for the other clients on the network.
4. **A refusal for the rate pauses everyone.** A 429 sets a pause that
   every later send waits out, and the refused request is sent once more
   after it. A refusal for the rate comes before execution, so a write is
   sent again too. A second refusal fails the request with the 429.
5. **The whole minute, whatever the body says.** The built-in transports
   report a refusal as a `TransportError`, its status and its body, without
   its headers. So the wrapper cannot read `Retry-After` over them, and it
   waits the full sixty seconds on every 429. That is the timeout AniList
   applies past its limit, so the header could only shorten the wait.
   Cloudflare's HTML body changes nothing, for the same reason. An app that
   wants the header's value reads it in a base transport of its own, which
   throws an error of its own carrying it, and `pause(after:)` reads that
   error.
6. **An outage is a value of the app's.** A 403 whose body says the API is
   temporarily disabled becomes `Outage`, an error type of the app's own.
   A 403 for any other reason stays the transport's error. Cloudflare's
   refusal of a client's signature, its code 1010, is one of those. Neither
   is sent again.
7. **A caller that went away leaves.** A request whose caller went away
   while it waited still takes its turn, and leaves without sending.

## In Swift

```swift
import Baton
import Foundation

/// The budget an app keeps around a rate-limited endpoint: one request in
/// flight, the most urgent first, no more sends in any minute than the
/// meter allows, and a pause for everyone after the server refuses one for
/// its rate. Copy it, and change the numbers to the endpoint's.
public struct Budget: Transport {
    /// How urgent a request is: a write the user made, then a refresh of
    /// what is on screen, then a page the user is browsing to.
    public enum Priority: Int, Comparable, Sendable {
        case browse, refresh, write

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The transport this wraps, which holds the endpoint and its credentials.
    public let base: any Transport
    /// How urgent a request is, as the app decides from its kind and name.
    public let priority: @Sendable (Request) -> Priority
    private let gate: Gate

    public init(
        base: any Transport,
        perMinute: Int = 25,
        priority: @escaping @Sendable (Request) -> Priority = { $0.kind == .mutation ? .write : .refresh }
    ) {
        self.base = base
        self.priority = priority
        gate = Gate(perMinute: perMinute)
    }

    /// How long every request waits after a refusal for the rate. The
    /// built-in transports report a refusal as its status and its body,
    /// without its headers, so `Retry-After` is not read here and the wait
    /// is the server's whole window.
    public static func pause(after error: any Error) -> Duration? {
        guard let transport = error as? TransportError, transport.statusCode == 429 else { return nil }
        return .seconds(60)
    }

    public func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await gate.enter(priority(request))
                do {
                    try await deliver(request, to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await gate.leave()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends the request in its turn, after the meter, and once more after
    /// the pause if the server refuses it for its rate.
    private func deliver(_ request: Request, to continuation: AsyncThrowingStream<Data, any Error>.Continuation) async throws {
        var refused = false
        while true {
            // A caller that went away while the request waited takes its
            // turn and leaves without sending.
            try Task.checkCancellation()
            try await gate.meter()
            do {
                for try await payload in base.send(request) { continuation.yield(payload) }
                return
            } catch {
                if let outage = Outage(error) { throw outage }
                guard let pause = Self.pause(after: error) else { throw error }
                await gate.pause(for: pause)
                // A refusal for the rate comes before execution, so even a
                // write is sent once more, after the pause.
                if refused { throw error }
                refused = true
            }
        }
    }
}

/// AniList switched off: a 403 whose body says the API is disabled. An
/// error of the app's own, which a handle's `fetch` carries as the
/// transport's kind of failure, beside the data the store still has.
public struct Outage: Error {
    init?(_ error: any Error) {
        guard let transport = error as? TransportError, transport.statusCode == 403,
              transport.body.contains("temporarily disabled") else { return nil }
    }
}

/// The one turn, the requests waiting for it, and the times of the last
/// minute's sends. Only the request holding the turn reads the meter.
private actor Gate {
    private let perMinute: Int
    private var busy = false
    private var waiting: [(priority: Budget.Priority, turn: CheckedContinuation<Void, Never>)] = []
    private var sent: [ContinuousClock.Instant] = []
    private var resumes = ContinuousClock.now

    init(perMinute: Int) { self.perMinute = perMinute }

    /// Waits until no request is in flight and none more urgent is waiting.
    func enter(_ priority: Budget.Priority) async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append((priority, $0)) }
    }

    /// Hands the turn to the most urgent waiting request, the earliest
    /// among equals.
    func leave() {
        guard let next = waiting.indices.max(by: { waiting[$0].priority < waiting[$1].priority }) else {
            busy = false
            return
        }
        waiting.remove(at: next).turn.resume()
    }

    /// Waits until the pause is over and a send fits in the minute, then
    /// counts the send.
    func meter() async throws {
        while true {
            let now = ContinuousClock.now
            sent.removeAll { $0 + .seconds(60) <= now }
            var until = resumes
            if sent.count >= perMinute, let oldest = sent.first { until = max(until, oldest + .seconds(60)) }
            if until <= now { break }
            try await Task.sleep(until: until)
        }
        sent.append(.now)
    }

    func pause(for duration: Duration) {
        resumes = max(resumes, .now + duration)
    }
}
```

The wiring puts the budget under the exchange, over the base transport
that holds the endpoint and its credentials. Browse pages are the
operation the app names for them:

```swift
@MainActor
func environment(token: @escaping @Sendable () async -> String) -> Environment {
    let anilist = URLSessionTransport(
        url: URL(string: "https://graphql.anilist.co")!,
        credentials: { ["Authorization": "Bearer \(await token())"] }
    )
    let budget = Budget(base: anilist, perMinute: 25) { request in
        if request.kind == .mutation { return .write }
        return request.operationName == "BrowseQuery" ? .browse : .refresh
    }
    return Environment(
        transport: Exchange(base: budget),
        store: Store(persistence: Persistence(name: "App", version: Types.schemaDigest))
    )
}
```

## In Kotlin

The Kotlin budget is one `flow` around the base transport's `send`, as
the Kotlin exchange is. The turn is a `Mutex` and a list of waiting
`CompletableDeferred`s. A request waits for its turn without being
cancelled, then checks whether its caller is still there, so the turn is
always handed on:

```kotlin
import baton.OperationKind
import baton.Request
import baton.Transport
import baton.TransportError
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The budget an app keeps around a rate-limited endpoint: one request in
 * flight, the most urgent first, no more sends in any minute than the
 * meter allows, and a pause for everyone after the server refuses one for
 * its rate. Copy it, and change the numbers to the endpoint's.
 */
class Budget(
    /** The transport this wraps, which holds the endpoint and its credentials. */
    val base: Transport,
    perMinute: Int = 25,
    /** How urgent a request is, as the app decides from its kind and name. */
    val priority: (Request) -> Priority = { if (it.kind == OperationKind.MUTATION) Priority.WRITE else Priority.REFRESH },
) : Transport {
    /** How urgent a request is: a page the user is browsing to, then a refresh of what is on screen, then a write the user made. */
    enum class Priority { BROWSE, REFRESH, WRITE }

    private val gate = Gate(perMinute)

    override fun send(request: Request): Flow<ByteArray> = flow {
        gate.enter(priority(request))
        try {
            var refused = false
            while (true) {
                // A caller that went away while the request waited takes its
                // turn and leaves without sending.
                currentCoroutineContext().ensureActive()
                gate.meter()
                try {
                    base.send(request).collect { emit(it) }
                    return@flow
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    Outage.of(error)?.let { throw it }
                    val pause = pause(error) ?: throw error
                    gate.pause(pause)
                    // A refusal for the rate comes before execution, so even
                    // a write is sent once more, after the pause.
                    if (refused) throw error
                    refused = true
                }
            }
        } finally {
            withContext(NonCancellable) { gate.leave() }
        }
    }

    companion object {
        /**
         * How long every request waits after [error], a refusal for the
         * rate. The built-in transports report a refusal as its status and
         * its body, without its headers, so `Retry-After` is not read here
         * and the wait is the server's whole window.
         */
        fun pause(error: Throwable): Duration? =
            if (error is TransportError && error.statusCode == 429) 60.seconds else null
    }
}

/**
 * AniList switched off: a 403 whose body says the API is disabled. An error
 * of the app's own, which a handle's `fetch` carries as the transport's
 * kind of failure, beside the data the store still has.
 */
class Outage : Exception("the API is temporarily disabled") {
    companion object {
        /** The outage [error] reports, or null for any other failure. */
        fun of(error: Throwable): Outage? =
            if (error is TransportError && error.statusCode == 403 && "temporarily disabled" in error.body) Outage() else null
    }
}

/**
 * The one turn, the requests waiting for it, and the times of the last
 * minute's sends. Only the request holding the turn reads the meter, so
 * the meter needs no lock.
 */
private class Gate(private val perMinute: Int) {
    private val lock = Mutex()
    private var busy = false
    private val waiting = mutableListOf<Pair<Budget.Priority, CompletableDeferred<Unit>>>()
    private val sent = ArrayDeque<TimeSource.Monotonic.ValueTimeMark>()
    private var resumes = TimeSource.Monotonic.markNow()

    /** Waits until no request is in flight and none more urgent is waiting. */
    suspend fun enter(priority: Budget.Priority) = withContext(NonCancellable) {
        val turn = lock.withLock {
            if (!busy) {
                busy = true
                return@withContext
            }
            CompletableDeferred<Unit>().also { waiting.add(priority to it) }
        }
        turn.await()
    }

    /** Hands the turn to the most urgent waiting request, the earliest among equals. */
    suspend fun leave() = lock.withLock {
        val next = waiting.maxByOrNull { it.first }
        if (next == null) {
            busy = false
            return@withLock
        }
        waiting.remove(next)
        next.second.complete(Unit)
    }

    /** Waits until the pause is over and a send fits in the minute, then counts the send. */
    suspend fun meter() {
        while (true) {
            while (sent.isNotEmpty() && sent.first().elapsedNow() >= 1.minutes) sent.removeFirst()
            var wait = -resumes.elapsedNow()
            if (sent.size >= perMinute) wait = maxOf(wait, 1.minutes - sent.first().elapsedNow())
            if (wait <= Duration.ZERO) break
            delay(wait)
        }
        sent.addLast(TimeSource.Monotonic.markNow())
    }

    fun pause(duration: Duration) {
        val until = TimeSource.Monotonic.markNow() + duration
        if (until > resumes) resumes = until
    }
}
```

The wiring is the same shape. On Android, an `OkHttpTransport` from
`baton-okhttp` stands where the `HttpTransport` stands:

```kotlin
fun environment(token: suspend () -> String): Environment {
    val anilist = HttpTransport(
        "https://graphql.anilist.co",
        credentials = { mapOf("Authorization" to "Bearer ${token()}") },
    )
    val budget = Budget(anilist, perMinute = 25) { request ->
        when {
            request.kind == OperationKind.MUTATION -> Budget.Priority.WRITE
            request.operationName == "BrowseQuery" -> Budget.Priority.BROWSE
            else -> Budget.Priority.REFRESH
        }
    }
    return Environment(
        Exchange(budget),
        store = Store(persistence = Persistence.named("App", version = Types.schemaDigest)),
    )
}
```

## The outage needs no new state

A handle already has the place for an outage. Its `fetch` is the last
fetch as a value: idle, in flight, or failed, with a `Failure` and the
time it failed. The budget throws `Outage`, and the handle's fetch carries
it as the transport's kind of failure, as the transport threw it. A view
reads it beside the data:

- With data in the store, from this launch or from the image, the phase
  stays ready and the data stays on screen. The fetch says why it is not
  fresher, and the view shows a calm line above it.
- Without data, the phase is failed, with the `Outage` itself, and the
  view shows the same line in place of the list.

That is [honest data](../principles/honest-data.md): a failed fetch is a
value beside the data, never a new phase and never a new kind of failure.
The list screen of
[the unpaged collection](unpaged-collection.md) reads it so:

```swift
var body: some View {
    switch list.phase {
    case .loading:
        ProgressView()
    case .ready(let data):
        Shelves(data: data)
            .safeAreaInset(edge: .top) {
                if list.fetch.failure?.error is Outage { OutageNote() }
            }
    case .failed(is Outage):
        OutageNote()
    case .failed(let error):
        ContentUnavailableView("No list", systemImage: "list.bullet", description: Text(error.localizedDescription))
    }
}
```

```kotlin
when (val phase = list.phase) {
    Phase.Loading -> CircularProgressIndicator()
    is Phase.Ready -> Column {
        if (list.fetch.failure?.error is Outage) OutageNote()
        Shelves(phase.data)
    }
    is Phase.Failed -> if (phase.error is Outage) OutageNote() else Text(phase.error.message.orEmpty())
}
```

Nothing in the runtime retries an outage, and nothing should guess when
it ends. The app calls `environment.revalidate()`, which refetches every
retained operation that is stale or whose last fetch failed, when it
returns to the foreground or from a timer of its own
([revalidation is the app's call](../decisions/revalidation-is-the-apps-call.md)).

## What was checked

The code on this page was compiled in both runtimes against AniList's
schema on 2026-10-18, beside the other recipes for the same API, and run
over a scripted base transport. Four requests sent while a first was in
flight, a browse page, a refresh, a write and another browse page, went
write, refresh, browse, browse. With `perMinute` at five, the sixth send
waited for the first to leave the minute. A body saying the API was temporarily disabled became
`Outage`, and Cloudflare's 403 with code 1010 stayed a `TransportError`.
A write refused once with a 429 was sent again sixty seconds later and
delivered. A query refused twice failed with the 429, and the next
request waited out the pause. The budget is not a sample of this
repository, and no test of the repository holds it: copy it, and test it
as your own.
