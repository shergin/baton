@_spi(Generated) import Baton
import BatonTesting
import FeedDocuments
import Foundation
import SQLite3
import Synchronization
import Testing

/// One tick of the feed, decoded off the main actor: the symbol it names,
/// its price and its time.
struct QuoteTick: Sendable {
    let symbol: String
    let price: Double
    let time: String
}

/// The newest tick of each symbol since the last drain. The code the docs
/// quote.
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

/// Commits what the pacer holds once per interval: every pending quote in
/// one payload, through the one client-only query, so a stream costs the
/// main actor one commit per interval whatever its rate. The code the docs
/// quote; an app passes `ContinuousClock()`.
func commitPaced(_ pacer: QuotePacer, to environment: Environment, every interval: Duration, clock: some Clock<Duration>) async {
    while !Task.isCancelled {
        do { try await clock.sleep(for: interval) } catch { return }
        let pending = await pacer.drain()
        if pending.isEmpty { continue }
        let response = LiveQuotes.RawResponse(liveQuotes: pending.map { .init(id: $0.symbol, price: $0.price, updatedAt: $0.time) })
        try? await environment.commitPayload(LiveQuotes(), response.payload)
    }
}

/// The pacer that lists every known symbol in every commit, in the order
/// each first ticked: the list only grows, so no commit drops a link. The
/// code the docs quote.
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

/// The paced loop over the listing pacer: a symbol that did not tick is
/// written by its id alone, which leaves its fields as they are. The loop
/// body is the code the docs quote.
func commitListing(_ pacer: ListingPacer, to environment: Environment, every interval: Duration, clock: some Clock<Duration>) async {
    while !Task.isCancelled {
        do { try await clock.sleep(for: interval) } catch { return }
        let listed = await pacer.drain()
        if listed.isEmpty { continue }
        let response = LiveQuotes.RawResponse(liveQuotes: listed.map { symbol, tick in
            guard let tick else { return .init(id: symbol) }
            return .init(id: symbol, price: tick.price, updatedAt: tick.time)
        })
        try? await environment.commitPayload(LiveQuotes(), response.payload)
    }
}

/// The app's own feed client, as test data: `ticks()` yields what the test
/// sends, as a client decoding each message off the main actor would.
final class LiveFeed: Sendable {
    private let stream: AsyncThrowingStream<QuoteTick, any Error>
    private let continuation: AsyncThrowingStream<QuoteTick, any Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream<QuoteTick, any Error>.makeStream()
    }

    func ticks() -> AsyncThrowingStream<QuoteTick, any Error> { stream }

    func send(_ tick: QuoteTick) { continuation.yield(tick) }
}

/// A clock the test moves by hand, so the pacer's interval passes when the
/// test says and not on the wall clock.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (left: Instant, right: Instant) -> Bool { left.offset < right.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// How many sleeps wait for the clock to move.
    var sleeping: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early: (any Error)?? = lock.withLock {
                    if Task.isCancelled { return .some(CancellationError()) }
                    if deadline <= current { return .some(nil) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                guard let early else { return }
                if let error = early { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock and wakes every sleep whose deadline it passed.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= current }
            for key in due.keys { sleepers.removeValue(forKey: key) }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// How many server batches the environment's log reported, and how many
/// slots they changed.
final class Commits: Sendable {
    private let state = Mutex((count: 0, changed: 0))

    func record(_ event: LogEvent) {
        guard case .committed(kind: .server, let changed) = event else { return }
        state.withLock {
            $0.count += 1
            $0.changed += changed
        }
    }

    var count: Int { state.withLock { $0.count } }
}

/// The paced shape of a service that commits a fast feed: ticks decoded off
/// the main actor, the newest per symbol kept, and once per interval one
/// payload through `LiveQuotes`, a client-only query whose one root field is
/// a client list of the server's own type, transient in `baton.json`.
@MainActor
@Suite("A paced commit of a feed through one client-only list query", .timeLimit(.minutes(1)))
struct PacedCommitTests {
    /// The quote of `symbol` as the server's query reads it, from the store.
    func storedQuote(_ environment: Environment, _ symbol: String) -> (QuoteQuery.Data.Quote?, Retention) {
        let handle = environment.handle(for: QuoteQuery(symbol: symbol), fetchPolicy: .storeOnly)
        let retention = handle.retain()
        guard case .ready(let data) = handle.phase else { return (nil, retention) }
        return (data.quote, retention)
    }

    /// The quote record of `symbol` through the server query's lens, for a
    /// symbol the server was never asked for, whose root cell is not written.
    func recordQuote(_ environment: Environment, _ symbol: String) -> QuoteQuery.Data.Quote? {
        guard let record = environment.store.existing("Quote:\(symbol)") else { return nil }
        return QuoteQuery.Data.Quote(anchor: Anchor(record: record, variables: QuoteQuery(symbol: symbol).variables, store: environment.store))
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

    /// One payload of `LiveQuotes` carrying the ticks.
    func payload(_ ticks: [QuoteTick]) -> Payload {
        LiveQuotes.RawResponse(liveQuotes: ticks.map { .init(id: $0.symbol, price: $0.price, updatedAt: $0.time) }).payload
    }

    @Test("the list query over the client extension compiles as client-only beside the schema directory, and nothing is sent for it: not by an attach, a commit, an invalidation or a revalidation")
    func the_list_query_is_client_only_and_never_sent() async throws {
        #expect(LiveQuotes.isClientOnly)
        #expect(!QuoteQuery.isClientOnly)
        let http = ScriptedTransport()
        let socket = ScriptedTransport()
        let environment = Environment(transport: http, subscriptions: socket)
        environment.log = nil
        let handle = environment.handle(for: LiveQuotes(), fetchPolicy: .networkOnly)
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let before) = handle.phase else {
            Issue.record("expected .ready at once, got \(handle.phase)")
            return
        }
        #expect(before.liveQuotes == nil, "no payload wrote the list yet")

        try await environment.commitPayload(LiveQuotes(), payload([QuoteTick(symbol: "AAPL", price: 101, time: "09:31")]))
        environment.invalidate()
        await handle.settle()
        environment.revalidate()
        await handle.settle()
        guard case .ready(let after) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        #expect(after.liveQuotes?.map(\.id) == ["AAPL"])
        #expect(http.requests.isEmpty, "the server's transport was asked for nothing")
        #expect(socket.requests.isEmpty, "the subscriptions' transport was asked for nothing")
        _ = consume retention
    }

    @Test("one payload carrying several quotes merges each into the record its server query reads, and a field the payload does not give stays as the server wrote it")
    func one_payload_merges_each_quote_into_the_server_record() async throws {
        let environment = Environment(transport: ScriptedTransport([QuoteQuery.name: serverQuote]))
        environment.log = nil
        let (quote, retention) = try await readQuote(environment)
        #expect(quote.quote?.price == 100)

        try await environment.commitPayload(LiveQuotes(), payload([
            QuoteTick(symbol: "AAPL", price: 101.5, time: "09:31"),
            QuoteTick(symbol: "MSFT", price: 410, time: "09:31"),
            QuoteTick(symbol: "NVDA", price: 120.25, time: "09:31"),
        ]))
        #expect(quote.quote?.price == 101.5, "the server query's lens sees the list's write")
        #expect(quote.quote?.updatedAt == "09:31")
        #expect(quote.quote?.name == "Apple", "the payload left out the name, so the record keeps the server's")
        let msft = recordQuote(environment, "MSFT")
        #expect(msft?.price == 410, "a quote the server never answered is a record of the server's type, which its query's lens reads")
        #expect(msft?.name == nil)
        _ = consume retention
    }

    @Test("the pacer turns many ticks for few symbols into one commit per interval carrying only the newest tick of each, and commits nothing for an interval without ticks")
    func the_pacer_commits_the_newest_tick_per_symbol_once_per_interval() async throws {
        let environment = Environment(transport: ScriptedTransport([QuoteQuery.name: serverQuote]))
        environment.log = nil
        let (quote, retention) = try await readQuote(environment)
        let live = environment.handle(for: LiveQuotes())
        let liveRetention = live.retain()
        let commits = Commits()
        environment.log = { commits.record($0) }
        let clock = ManualClock()
        let pacer = QuotePacer()
        let loop = Task { await commitPaced(pacer, to: environment, every: .milliseconds(100), clock: clock) }
        #expect(await wait(until: { clock.sleeping == 1 }))

        let symbols = ["AAPL", "MSFT", "NVDA"]
        for index in 0..<30 {
            await pacer.offer(QuoteTick(symbol: symbols[index % 3], price: Double(200 + index), time: "09:31:\(index)"))
        }
        #expect(commits.count == 0, "a tick is not a commit")
        clock.advance(by: .milliseconds(100))
        #expect(await wait(until: { commits.count == 1 }))
        guard case .ready(let data) = live.phase else {
            Issue.record("expected .ready, got \(live.phase)")
            return
        }
        let committed = try #require(data.liveQuotes)
        #expect(committed.map(\.id).sorted() == symbols, "one entry per symbol, not one per tick")
        #expect(committed.first { $0.id == "AAPL" }?.price == 227, "the newest of AAPL's ten ticks")
        #expect(committed.first { $0.id == "NVDA" }?.price == 229)
        #expect(quote.quote?.price == 227)
        #expect(quote.quote?.updatedAt == "09:31:27")
        #expect(quote.quote?.name == "Apple")

        #expect(await wait(until: { clock.sleeping == 1 }))
        clock.advance(by: .milliseconds(100))
        #expect(await wait(until: { clock.sleeping == 1 }), "the loop came around")
        #expect(commits.count == 1, "an interval without ticks commits nothing")

        for index in 0..<5 {
            await pacer.offer(QuoteTick(symbol: "MSFT", price: Double(400 + index), time: "09:32:\(index)"))
        }
        clock.advance(by: .milliseconds(100))
        #expect(await wait(until: { commits.count == 2 }))
        guard case .ready(let next) = live.phase else {
            Issue.record("expected .ready, got \(live.phase)")
            return
        }
        #expect(next.liveQuotes?.map(\.id) == ["MSFT"], "the list holds what the last interval drained")
        #expect(next.liveQuotes?.first?.price == 404)
        #expect(quote.quote?.price == 227, "a quote the interval did not carry keeps its last price")
        loop.cancel()
        await loop.value
        _ = consume liveRetention
        _ = consume retention
    }

    @Test("with the image attached, the transient list's cell is not written while the quotes' records are: a second store over the image reads the new price through the server's query and finds nothing for the list")
    func the_image_keeps_the_quotes_and_not_the_transient_list() async throws {
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("baton-feed-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-discard"] { try? FileManager.default.removeItem(atPath: image.path + suffix) }
        }
        let first = Environment(transport: ScriptedTransport([QuoteQuery.name: serverQuote]), store: Store(persistence: Persistence(url: image)))
        first.log = nil
        let (quote, retention) = try await readQuote(first)
        try await first.commitPayload(LiveQuotes(), payload([
            QuoteTick(symbol: "AAPL", price: 105, time: "09:35"),
            QuoteTick(symbol: "MSFT", price: 411, time: "09:35"),
        ]))
        #expect(quote.quote?.price == 105)
        await first.store.persistence?.close()
        _ = consume retention

        #expect(integer(image, "SELECT count(*) FROM root WHERE field LIKE 'liveQuotes%'") == 0, "the transient root field's cell is not written")
        #expect(integer(image, "SELECT count(*) FROM fetches WHERE operation LIKE 'LiveQuotes%'") == 0)
        #expect(integer(image, "SELECT count(*) FROM records WHERE key = 'Quote:AAPL'") == 1)
        #expect(integer(image, "SELECT count(*) FROM records WHERE key = 'Quote:MSFT'") == 1, "a quote only the list linked is written too")
        #expect(integer(image, "SELECT count(*) FROM root WHERE field LIKE 'quote(%'") == 1)

        let transport = ScriptedTransport()
        let second = Environment(transport: transport, store: Store(persistence: Persistence(url: image)))
        second.log = nil
        let (stored, storedRetention) = storedQuote(second, "AAPL")
        #expect(stored?.price == 105, "the server's query reads the price the list wrote")
        #expect(stored?.name == "Apple")
        let live = second.handle(for: LiveQuotes())
        let liveRetention = live.retain()
        guard case .ready(let data) = live.phase else {
            Issue.record("expected .ready, got \(live.phase)")
            return
        }
        #expect(data.liveQuotes == nil, "the list's cell did not reach the image")
        #expect(transport.requests.isEmpty)
        _ = consume liveRetention
        _ = consume storedRetention
        await second.store.persistence?.close()
    }

    @Test("committing many symbols through the list query parks one root and runs no collection, where the same ticks through the server's query of more than ten unheld symbols evict a root and run a collection per commit")
    func the_list_query_evicts_nothing_where_a_root_per_symbol_does() async throws {
        let symbols = (0..<20).map { "S\($0)" }
        let rounds = 5
        func ticks(_ round: Int) -> [QuoteTick] {
            symbols.enumerated().map { QuoteTick(symbol: $1, price: Double(round * 100 + $0), time: "09:\(30 + round)") }
        }

        let paced = Environment(transport: ScriptedTransport())
        paced.log = nil
        let pacedRoots = paced.store.rootCount
        for round in 0..<rounds {
            try await paced.commitPayload(LiveQuotes(), payload(ticks(round)))
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(paced.store.rootCount == pacedRoots + 1, "one root, the list's, waits in the release buffer")
        #expect(paced.store.collections == 0, "no root was pushed out, so no collection was scheduled")
        #expect(recordQuote(paced, "S7")?.price == Double((rounds - 1) * 100 + 7))

        let perTick = Environment(transport: ScriptedTransport())
        perTick.log = nil
        for round in 0..<rounds {
            for tick in ticks(round) {
                let response = QuoteQuery.RawResponse(quote: .init(id: tick.symbol, price: tick.price, updatedAt: tick.time))
                try await perTick.commitPayload(QuoteQuery(symbol: tick.symbol), response.payload)
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(perTick.store.rootCount == perTick.store.releaseBufferSize, "a root per symbol, and the buffer keeps ten")
        let evictions = rounds * symbols.count - perTick.store.releaseBufferSize
        #expect(perTick.store.collections == evictions, "every commit past the buffer's ten pushed a root out, and each ran a collection")
    }

    @Test("a list that leaves out a symbol of the last one schedules a collection, and one that keeps every known symbol in order, an unchanged one by id alone, schedules none")
    func a_list_that_drops_a_symbol_schedules_a_collection() async throws {
        let environment = Environment(transport: ScriptedTransport())
        environment.log = nil
        let symbols = (0..<5).map { "S\($0)" }
        try await environment.commitPayload(LiveQuotes(), payload(symbols.map { QuoteTick(symbol: $0, price: 1, time: "09:30") }))
        for _ in 0..<20 { await Task.yield() }
        let before = environment.store.collections

        try await environment.commitPayload(LiveQuotes(), payload([QuoteTick(symbol: "S1", price: 2, time: "09:31")]))
        for _ in 0..<20 { await Task.yield() }
        #expect(environment.store.collections == before + 1, "the list no longer links four of its quotes, which may have left them unreachable")

        try await environment.commitPayload(LiveQuotes(), payload(symbols.map { QuoteTick(symbol: $0, price: 3, time: "09:32") }))
        for _ in 0..<20 { await Task.yield() }
        let settled = environment.store.collections
        let listed = (symbols + ["S5"]).map { symbol in
            symbol == "S1" || symbol == "S5" ? LiveQuotes.RawResponse.LiveQuotes(id: symbol, price: 4, updatedAt: "09:33") : .init(id: symbol)
        }
        try await environment.commitPayload(LiveQuotes(), LiveQuotes.RawResponse(liveQuotes: listed).payload)
        for _ in 0..<20 { await Task.yield() }
        #expect(environment.store.collections == settled, "a list that only grew keeps every link it had")
        #expect(recordQuote(environment, "S1")?.price == 4)
        #expect(recordQuote(environment, "S5")?.price == 4)
        #expect(recordQuote(environment, "S3")?.price == 3, "a quote given by its id alone keeps its price")
        #expect(recordQuote(environment, "S3")?.updatedAt == "09:32")
    }

    @Test("the listing pacer, across intervals in which different symbols tick, commits a list that only grows: no collection is scheduled, each ticked symbol's price is written and an unticked one's fields stay")
    func the_listing_pacer_commits_a_list_that_only_grows() async throws {
        let environment = Environment(transport: ScriptedTransport())
        environment.log = nil
        let live = environment.handle(for: LiveQuotes())
        let liveRetention = live.retain()
        let commits = Commits()
        environment.log = { commits.record($0) }
        let clock = ManualClock()
        let pacer = ListingPacer()
        let loop = Task { await commitListing(pacer, to: environment, every: .milliseconds(100), clock: clock) }

        func interval(_ ticks: [QuoteTick], commitsAfter: Int) async {
            for tick in ticks { await pacer.offer(tick) }
            #expect(await wait(until: { clock.sleeping == 1 }))
            clock.advance(by: .milliseconds(100))
            #expect(await wait(until: { commits.count == commitsAfter && clock.sleeping == 1 }))
            for _ in 0..<20 { await Task.yield() }
        }
        func listed() -> [String]? {
            guard case .ready(let data) = live.phase else { return nil }
            return data.liveQuotes?.map(\.id)
        }

        await interval(["S0", "S1", "S2", "S3", "S4"].map { QuoteTick(symbol: $0, price: 1, time: "09:30") }, commitsAfter: 1)
        #expect(listed() == ["S0", "S1", "S2", "S3", "S4"])
        await interval([QuoteTick(symbol: "S1", price: 2, time: "09:31"), QuoteTick(symbol: "S3", price: 2, time: "09:31")], commitsAfter: 2)
        #expect(listed() == ["S0", "S1", "S2", "S3", "S4"], "the symbols that did not tick are still listed")
        await interval([QuoteTick(symbol: "S5", price: 3, time: "09:32"), QuoteTick(symbol: "S0", price: 3, time: "09:32")], commitsAfter: 3)
        #expect(listed() == ["S0", "S1", "S2", "S3", "S4", "S5"], "a new symbol is appended")
        await interval([], commitsAfter: 3)
        #expect(commits.count == 3, "an interval without ticks commits nothing")

        #expect(environment.store.collections == 0, "no commit dropped a link")
        #expect(recordQuote(environment, "S0")?.price == 3)
        #expect(recordQuote(environment, "S1")?.price == 2)
        #expect(recordQuote(environment, "S3")?.updatedAt == "09:31")
        #expect(recordQuote(environment, "S5")?.price == 3)
        #expect(recordQuote(environment, "S2")?.price == 1, "a symbol listed by its id alone keeps its price")
        #expect(recordQuote(environment, "S4")?.updatedAt == "09:30")
        loop.cancel()
        await loop.value
        _ = consume liveRetention
    }

    @Test("the service's wiring runs: ticks a feed yields off the main actor reach the store through the pacing loop, and cancelling both tasks and releasing the list's retention ends it")
    func the_service_wiring_runs_off_the_main_actor() async throws {
        let environment = Environment(transport: ScriptedTransport())
        environment.log = nil
        let commits = Commits()
        environment.log = { commits.record($0) }
        let feed = LiveFeed()

        let pacer = QuotePacer()
        let live = environment.handle(for: LiveQuotes())
        let retention = live.retain()
        let feeding = Task.detached {
            for try await tick in feed.ticks() { await pacer.offer(tick) }
        }
        let pacing = Task.detached {
            await commitPaced(pacer, to: environment, every: .milliseconds(33), clock: ContinuousClock())
        }

        for index in 0..<10 {
            feed.send(QuoteTick(symbol: index % 2 == 0 ? "AAPL" : "MSFT", price: Double(100 + index), time: "09:31:\(index)"))
        }
        #expect(await wait(until: { recordQuote(environment, "AAPL")?.price == 108 && recordQuote(environment, "MSFT")?.price == 109 }))
        #expect(commits.count >= 1)
        #expect(commits.count <= 10, "ticks were paced, not committed one by one")

        feeding.cancel()
        pacing.cancel()
        _ = try? await feeding.value
        await pacing.value
        _ = consume retention
        let ended = commits.count
        await pacer.offer(QuoteTick(symbol: "AAPL", price: 200, time: "09:40"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(commits.count == ended, "no loop is left to commit")
        #expect(recordQuote(environment, "AAPL")?.price == 108)
    }

    @Test("commitPayload commits while the environment is inactive, and the service's refetch of its held server query fetches the baseline again")
    func a_commit_lands_while_inactive_and_refetch_restores_the_baseline() async throws {
        let transport = ScriptedTransport([QuoteQuery.name: serverQuote])
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: QuoteQuery(symbol: "AAPL"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let quote) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }

        environment.isActive = false
        try await environment.commitPayload(LiveQuotes(), payload([QuoteTick(symbol: "AAPL", price: 120, time: "09:50")]))
        #expect(quote.quote?.price == 120, "the commit landed while inactive")
        #expect(quote.quote?.updatedAt == "09:50")

        environment.isActive = true
        try await handle.refetch()
        #expect(transport.requests.map(\.operationName) == [QuoteQuery.name, QuoteQuery.name], "the refetch sent the server's query again")
        #expect(quote.quote?.price == 100, "the baseline is the server's again")
        _ = consume retention
    }

    /// The first column of the first row a read-only query of the image
    /// returns, as an integer.
    func integer(_ url: URL, _ text: String) -> Int64? {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK, "\(text)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }
}
