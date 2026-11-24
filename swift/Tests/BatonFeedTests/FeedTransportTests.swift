import Baton
import BatonTesting
import FeedDocuments
import Foundation
import Observation
import Testing

/// The app's client for the feed's own protocol, as test data: each call to
/// `ticks` opens a stream the test drives, and the feed records the symbol it
/// was asked for and whether its reader ended the stream.
final class QuoteFeed: @unchecked Sendable {
    struct Tick: Sendable {
        let price: Double
        let time: String
    }

    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<Tick, any Error>.Continuation] = []
    private var asked: [String] = []
    private var terminated: [Bool] = []

    func ticks(symbol: String) -> AsyncThrowingStream<Tick, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Tick, any Error>.makeStream()
        lock.withLock {
            let index = continuations.count
            continuations.append(continuation)
            asked.append(symbol)
            terminated.append(false)
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.terminated[index] = true } }
        }
        return stream
    }

    /// How many times the feed was asked for ticks.
    var opens: Int { lock.withLock { continuations.count } }

    /// The symbols it was asked for, in order.
    var symbols: [String] { lock.withLock { asked } }

    /// Whether the stream of the `index`th open has ended.
    func ended(_ index: Int) -> Bool { lock.withLock { terminated[index] } }

    /// Delivers a tick on the newest stream.
    func tick(price: Double, time: String) {
        _ = lock.withLock { continuations.last }?.yield(Tick(price: price, time: time))
    }

    /// Breaks the newest stream, as a dropped connection does.
    func drop() {
        lock.withLock { continuations.last }?.finish(throwing: FeedDropped())
    }
}

/// The feed's connection dropped.
struct FeedDropped: Error {}

/// The transport an app writes for a backend of another protocol: the feed's
/// subscription is answered from the feed's ticks, each written with the
/// operation's raw response, and every other request goes to the server's
/// transport. The code `docs/recipes` quotes.
struct FeedTransport: Transport {
    let server: any Transport
    let feed: QuoteFeed

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

/// What the GraphQL server answers for the quote: the response a server
/// writes, not a builder's, so the feed's builder is checked against it.
let serverQuote = Data(#"{"data":{"quote":{"id":"AAPL","name":"Apple","price":100.0,"updatedAt":"09:30"}}}"#.utf8)

/// A trade the server streams itself.
let serverTrade = Data(#"{"data":{"tradeExecuted":{"id":"T1","size":10,"quote":{"id":"AAPL","price":99.5}}}}"#.utf8)

@MainActor
@Suite("A transport of the app's own for a backend of another protocol", .timeLimit(.minutes(1)))
struct FeedTransportTests {
    final class Counter: @unchecked Sendable {
        var fired = 0
    }

    /// The quote as the query's handle reads it, once the server answered.
    func readQuote(_ environment: Environment) async throws -> (QuoteQuery.Data, Retention) {
        let handle = environment.handle(for: QuoteQuery(symbol: "AAPL"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            throw TransportError(statusCode: 0, body: "the quote did not arrive: \(handle.phase)")
        }
        return (data, retention)
    }

    func isWaiting(_ stream: Baton.Stream) -> Bool {
        guard case .waiting = stream else { return false }
        return true
    }

    func isIdle(_ stream: Baton.Stream) -> Bool {
        guard case .idle = stream else { return false }
        return true
    }

    @Test("a subscription to the feed's field is answered by the app's transport from the feed's ticks, and each tick merges into the record the query reads, so the query's view sees it")
    func a_feed_tick_merges_into_the_record_the_query_reads() async throws {
        let http = ScriptedTransport([QuoteQuery.name: serverQuote])
        let socket = ScriptedTransport()
        let feed = QuoteFeed()
        let environment = Environment(transport: http, subscriptions: FeedTransport(server: socket, feed: feed))
        environment.log = nil
        let (quote, retention) = try await readQuote(environment)
        #expect(quote.quote?.price == 100)

        let counter = Counter()
        withObservationTracking { _ = quote.quote?.price } onChange: { counter.fired += 1 }
        let live = environment.subscriptionHandle(for: QuoteTicks(symbol: "AAPL"))
        let liveRetention = live.retain()
        #expect(await wait(until: { feed.opens == 1 }))
        #expect(feed.symbols == ["AAPL"], "the transport read the symbol from the request's variables")

        feed.tick(price: 101.5, time: "09:31")
        #expect(await wait(until: { live.events == 1 }))
        #expect(live.latest?.quoteChanged.price == 101.5)
        #expect(live.latest?.quoteChanged.updatedAt == "09:31")
        #expect(counter.fired == 1, "the tick invalidated the query's view of the price")
        #expect(quote.quote?.price == 101.5)
        #expect(quote.quote?.updatedAt == "09:31")
        #expect(quote.quote?.name == "Apple", "a field the tick does not carry stays as the server wrote it")

        feed.tick(price: 102, time: "09:32")
        #expect(await wait(until: { live.events == 2 }))
        #expect(quote.quote?.price == 102)
        #expect(socket.requests.isEmpty, "the feed's subscription never reached the server's socket")
        #expect(http.requests.map(\.operationName) == [QuoteQuery.name])
        _ = consume liveRetention
        _ = consume retention
    }

    @Test("a query and a subscription the server owns pass through the app's transport to the server's, with the request as the environment wrote it")
    func every_other_request_reaches_the_server_untouched() async throws {
        let http = ScriptedTransport([QuoteQuery.name: serverQuote])
        let socket = ScriptedTransport()
        let feed = QuoteFeed()
        let environment = Environment(transport: FeedTransport(server: http, feed: feed), subscriptions: FeedTransport(server: socket, feed: feed))
        environment.log = nil
        let (quote, retention) = try await readQuote(environment)
        #expect(quote.quote?.name == "Apple")
        let query = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(query.operationName == QuoteQuery.name)
        #expect(query.kind == .query)
        #expect(query.document == QuoteQuery.document)
        #expect(query.variables == QuoteQuery(symbol: "AAPL").variables)

        let trades = environment.subscriptionHandle(for: TradeTicks(symbol: "AAPL"))
        let tradesRetention = trades.retain()
        #expect(await wait(until: { socket.driven.count == 1 }))
        let driven = try #require(socket.driven.first)
        #expect(driven.request.operationName == TradeTicks.name)
        #expect(driven.request.kind == .subscription)
        #expect(driven.request.document == TradeTicks.document)
        #expect(driven.request.variables == TradeTicks(symbol: "AAPL").variables)
        driven.send(serverTrade)
        #expect(await wait(until: { trades.events == 1 }))
        #expect(trades.latest?.tradeExecuted?.size == 10)
        #expect(quote.quote?.price == 99.5, "the server's own subscription merges into the same record")
        #expect(feed.opens == 0, "no request but the feed's subscription reached the feed")
        _ = consume tradesRetention
        _ = consume retention
    }

    @Test("a raw response committed through the door writes the fields it gives and leaves a field of the record it does not give untouched")
    func a_raw_response_committed_through_the_door_writes_only_its_fields() async throws {
        let environment = Environment(transport: ScriptedTransport([QuoteQuery.name: serverQuote]))
        environment.log = nil
        let (quote, retention) = try await readQuote(environment)
        let counter = Counter()
        withObservationTracking { _ = quote.quote?.price } onChange: { counter.fired += 1 }

        let response = QuoteQuery.RawResponse(quote: .init(id: "AAPL", price: 103.25, updatedAt: "09:33"))
        try await environment.commitPayload(QuoteQuery(symbol: "AAPL"), response.payload)
        #expect(counter.fired == 1)
        #expect(quote.quote?.price == 103.25)
        #expect(quote.quote?.updatedAt == "09:33")
        #expect(quote.quote?.name == "Apple", "the raw response left out the name, so the record keeps the server's")
        _ = consume retention
    }

    @Test("a raw response renders the response body a server writes: the fields given under data, the fields left out absent")
    func a_raw_response_renders_a_response_body() throws {
        let response = QuoteTicks.RawResponse(quoteChanged: .init(id: "AAPL", price: 101.5))
        let object = try #require(try JSONSerialization.jsonObject(with: response.payload.bytes) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let quote = try #require(data["quoteChanged"] as? [String: Any])
        #expect(quote["id"] as? String == "AAPL")
        #expect(quote["price"] as? Double == 101.5)
        #expect(quote.keys.sorted() == ["id", "price"], "updatedAt was not given, so the body leaves it out")
    }

    @Test("the directive is not sent: the subscription's and the query's text carry their fields and no raw_response_type")
    func the_directive_is_not_sent() throws {
        let subscription = try #require(QuoteTicks.text)
        let query = try #require(QuoteQuery.text)
        #expect(subscription.contains("quoteChanged(symbol:$symbol)"))
        #expect(!subscription.contains("raw_response_type"))
        #expect(!query.contains("raw_response_type"))
    }

    @Test("a feed stream that fails is opened again by the handle after its backoff, as a built-in transport's is, and its ticks go on")
    func a_failed_feed_stream_is_reopened_by_the_handle() async throws {
        let feed = QuoteFeed()
        let environment = Environment(transport: ScriptedTransport(), subscriptions: FeedTransport(server: ScriptedTransport(), feed: feed))
        environment.log = nil
        let live = environment.subscriptionHandle(for: QuoteTicks(symbol: "AAPL"))
        let retention = live.retain()
        #expect(await wait(until: { feed.opens == 1 }))
        feed.tick(price: 101, time: "09:31")
        #expect(await wait(until: { live.events == 1 }))

        feed.drop()
        #expect(await wait(until: { isWaiting(live.stream) }))
        #expect(live.error is FeedDropped, "the feed's own error is the handle's")
        #expect(await wait(until: { feed.opens == 2 }), "the backoff opened the feed again")
        #expect(live.resumptions == 1)
        #expect(feed.ended(0))
        #expect(feed.symbols == ["AAPL", "AAPL"])
        feed.tick(price: 104, time: "09:34")
        #expect(await wait(until: { live.events == 2 }))
        #expect(live.latest?.quoteChanged.price == 104)
        #expect(live.error == nil)
        _ = consume retention
    }

    @Test("releasing the handle ends the feed's stream through the app's transport, and the feed is not opened again")
    func releasing_the_handle_ends_the_feed_stream() async throws {
        let feed = QuoteFeed()
        let environment = Environment(transport: ScriptedTransport(), subscriptions: FeedTransport(server: ScriptedTransport(), feed: feed))
        environment.log = nil
        let live = environment.subscriptionHandle(for: QuoteTicks(symbol: "AAPL"))
        let retention = live.retain()
        #expect(await wait(until: { feed.opens == 1 }))
        feed.tick(price: 101, time: "09:31")
        #expect(await wait(until: { live.events == 1 }))
        #expect(!feed.ended(0))

        _ = consume retention
        #expect(isIdle(live.stream))
        #expect(await wait(until: { feed.ended(0) }), "the release cancelled the transport's task, which ended the feed's stream")
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.opens == 1)
    }

    @Test("a mutation carrying raw_response_type keeps its optimistic response and its action, the same as one without it")
    func a_mutation_with_the_directive_is_unchanged() async throws {
        #expect(SetAlert.Action.self == MutationAction<SetAlert>.self)
        #expect(SetAlert.text == SetAlertPlain.text?.replacingOccurrences(of: "SetAlertPlain", with: "SetAlert"))
        let optimistic = SetAlert.OptimisticResponse(setAlert: .init(id: "AAPL", alertPrice: 150))
        let plain = SetAlertPlain.OptimisticResponse(setAlert: .init(id: "AAPL", alertPrice: 150))
        #expect(optimistic.payload == plain.payload)

        let transport = ScriptedTransport([QuoteQuery.name: serverQuote])
        let environment = Environment(transport: transport)
        environment.log = nil
        let (quote, retention) = try await readQuote(environment)
        let mutation = Task { try await environment.mutate(SetAlert(symbol: "AAPL", price: 150), optimistic: optimistic.payload) }
        #expect(await wait(until: { transport.held.count == 1 }))
        #expect(environment.store.optimisticLayers.count == 1)
        try #require(transport.held.first).respond(Data(#"{"data":{"setAlert":{"id":"AAPL","alertPrice":150.0}}}"#.utf8))
        let data = try await mutation.value
        #expect(data.setAlert?.alertPrice == 150)
        #expect(environment.store.optimisticLayers.isEmpty)
        #expect(quote.quote?.name == "Apple")
        _ = consume retention
    }
}
