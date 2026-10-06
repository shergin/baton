@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import SwiftUI
import Testing

/// A second page of the fixture: the same shape, every id shifted so the
/// records are distinct.
func shiftedFixture(by offset: Int) -> Data {
    let text = String(decoding: fixtureData, as: UTF8.self)
    let regex = try! NSRegularExpression(pattern: "\"id\":\"(\\d+)\"")
    let mutable = NSMutableString(string: text)
    var location = 0
    while let match = regex.firstMatch(in: mutable as String, range: NSRange(location: location, length: mutable.length - location)) {
        let id = Int(mutable.substring(with: match.range(at: 1)))!
        let replacement = "\"id\":\"\(id + offset)\""
        mutable.replaceCharacters(in: match.range, with: replacement)
        location = match.range.location + replacement.utf16.count
    }
    return Data((mutable as String).utf8)
}

/// Counts the requests a transport has answered, across threads.
final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The number of this attempt, from 1.
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A view holding an operation's storage, as a `@Query` property expands to.
struct StorageProbe: View {
    let storage: OperationStorage<TestHeaderQuery>

    var body: some View {
        if case .ready(let data) = storage.resolved.phase {
            Text(data.character?.testHeader.name ?? "")
        } else {
            Text("loading")
        }
    }
}

/// A screen's model, as an app writes one outside SwiftUI: it holds the
/// handle and the retention that keeps its records, and lets both go with
/// itself.
@MainActor
final class CharactersModel {
    let handle: OperationHandle<TestList>
    private let retention: Retention

    init(environment: Baton.Environment) {
        handle = environment.handle(for: TestList(page: 1))
        retention = handle.retain()
    }

    var firstName: String? {
        guard case .ready(let data) = handle.phase else { return nil }
        return data.characters?.results?.first?.testRow.name
    }
}

@MainActor
@Suite("Lifetime", .timeLimit(.minutes(1)))
struct LifetimeTests {
    /// A transport that serves the fixture for any page, shifted by page
    /// number, and a character's header for a lookup by id.
    func transport() -> RecordedTransport {
        RecordedTransport { request in
            if request.operationName == TestHeaderQuery.name, case .string(let id)? = request.variables["id"] {
                return fixture("character-header-\(id)")
            }
            guard case .int(let page)? = request.variables["page"] else { return fixtureData }
            return page == 1 ? fixtureData : shiftedFixture(by: page * 100_000)
        }
    }

    @Test("a screen left and re-entered within the buffer makes no request")
    func reentryWithinTheBuffer() async {
        let transport = transport()
        let environment = Environment(transport: transport, store: Store(releaseBufferSize: 2))

        let first = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let firstRetention = first.retain()
        await first.settle()
        #expect(transport.requestCount == 1)
        _ = consume firstRetention

        // Back within the buffer: same handle, complete and fresh, no request.
        let again = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(again === first)
        guard case .ready = again.phase else { Issue.record("expected ready"); return }
        #expect(transport.requestCount == 1)
        let againRetention = again.retain()
        _ = consume againRetention

        // Two more released handles push it out of a buffer of two.
        for page in 2...3 {
            let other = environment.handle(for: TestList(page: page), fetchPolicy: .storeOrNetwork)
            let otherRetention = other.retain()
            await other.settle()
            _ = consume otherRetention
        }
        // Eviction schedules a collection; once it has run, page 1 is gone from
        // the store and the next attach must fetch again.
        environment.store.collect()
        #expect(environment.store.existing("Character:1") == nil)
        let evicted = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(evicted !== first)
        await evicted.settle()
        #expect(transport.requestCount == 4, "pages 1, 2, 3, then 1 again after eviction")
    }

    @Test("collection removes records no root reaches and keeps shared ones")
    func collection() async {
        let environment = Environment(transport: transport(), store: Store(releaseBufferSize: 0))

        let page1 = environment.handle(for: TestList(page: 1))
        let page1Retention = page1.retain()
        await page1.settle()
        // The list plan stores what it selects: 20 characters and their origins.
        let afterPage1 = environment.store.count
        #expect(afterPage1 > 20)

        let page2 = environment.handle(for: TestList(page: 2))
        let page2Retention = page2.retain()
        await page2.settle()
        #expect(environment.store.count > afterPage1)

        // Releasing page 2 with an empty buffer evicts it; collection follows.
        _ = consume page2Retention
        let removed = environment.store.collect()
        #expect(removed > 0)
        #expect(environment.store.count == afterPage1)
        #expect(environment.store.existing("Character:1") != nil)
        #expect(environment.store.existing("Character:200001") == nil)

        // The retained page still reads.
        guard case .ready(let data) = page1.phase else { Issue.record("page 1 should stay ready"); return }
        #expect(data.characters?.results?.first?.testRow.name == "Rick Sanchez")
        withExtendedLifetime(page1Retention) {}
    }

    @Test("a collected lookup by id takes its entry out of the root, a retained one keeps it, and the collected field reads as missing data")
    func collectionPrunesTheRootsLookups() async throws {
        final class Misses: @unchecked Sendable { var reads: [String] = [] }
        let transport = RecordedTransport { request in
            guard case .string(let id)? = request.variables["id"] else { return nil }
            return fixture("character-header-\(id)")
        }
        let environment = Environment(transport: transport, store: Store(releaseBufferSize: 0))
        let misses = Misses()
        environment.store.reportMissing = { record, slot in misses.reads.append(record.key + "." + slot.storageKey) }
        let root = environment.store.root
        let before = root.renderedKeyCount

        let kept = environment.handle(for: TestHeaderQuery(id: "5"))
        let keptRetention = kept.retain()
        await kept.settle()
        let dropped = environment.handle(for: TestHeaderQuery(id: "11"))
        let droppedRetention = dropped.retain()
        await dropped.settle()
        #expect(root.renderedKeyCount == before + 2, "one entry per id looked up")
        guard case .ready(let stale) = dropped.phase else { Issue.record("expected ready, got \(dropped.phase)"); return }
        #expect(stale.character?.testHeader.name == "Albert Einstein")

        // Released with an empty buffer, the lookup is evicted at once.
        _ = consume droppedRetention
        environment.store.collect()
        #expect(environment.store.existing("Character:11") == nil)
        #expect(environment.store.existing("Character:5") != nil)
        #expect(root.renderedKeyCount == before + 1, "the collected lookup's entry left with its record; the retained one stayed")

        // Data a view still holds reads as missing rather than crashing,
        // and the store has nothing left to answer the lookup with.
        #expect(misses.reads.isEmpty)
        #expect(stale.character?.testHeader.name ?? "" == "")
        #expect(!misses.reads.isEmpty, "the read of the collected field was reported")
        let again = environment.handle(for: TestHeaderQuery(id: "11"), fetchPolicy: .storeOnly)
        guard case .failed(let error) = again.phase, error is MissingDataError else {
            Issue.record("expected the collected lookup to be missing, got \(again.phase)")
            return
        }
        #expect(root.renderedKeyCount == before + 1, "a failed lookup writes no entry")

        guard case .ready(let data) = kept.phase else { Issue.record("the retained lookup stays ready, got \(kept.phase)"); return }
        #expect(data.character?.testHeader.name == "Jerry Smith")
        _ = consume keptRetention
        environment.store.collect()
        #expect(root.renderedKeyCount == before, "the root is back to what it was before either lookup")
    }

    @Test("storeOrNetwork reads a complete store without fetching; storeAndNetwork fetches anyway")
    func policies() async throws {
        let transport = transport()
        let environment = Environment(transport: transport)
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))

        let quiet = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        guard case .ready = quiet.phase else { Issue.record("expected ready from the store"); return }
        await quiet.settle()
        #expect(transport.requestCount == 0)

        let eager = environment.handle(for: TestHeaderQuery(id: "5"), fetchPolicy: .storeAndNetwork)
        guard case .ready = eager.phase else { Issue.record("expected ready from the lookup"); return }
        #expect(eager.isRefreshing)
        await eager.settle()
        #expect(transport.requestCount == 1)

        let networkOnly = environment.handle(for: TestHeaderQuery(id: "11"), fetchPolicy: .networkOnly)
        guard case .loading = networkOnly.phase else { Issue.record("networkOnly must not render from the store"); return }
        await networkOnly.settle()
        guard case .ready = networkOnly.phase else { Issue.record("networkOnly should be ready after its fetch"); return }

        let offline = environment.handle(for: TestHeaderQuery(id: "999"), fetchPolicy: .storeOnly)
        guard case .failed(let error) = offline.phase, error is MissingDataError else {
            Issue.record("storeOnly must fail without data")
            return
        }
        #expect(transport.requestCount == 2)
    }

    @Test("invalidate marks data stale and retained handles refetch")
    func invalidation() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        let handle = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let retention = handle.retain()
        await handle.settle()
        #expect(transport.requestCount == 1)
        #expect(!handle.isStale)

        environment.invalidate()
        #expect(handle.isStale)
        guard case .ready = handle.phase else { Issue.record("data stays visible while stale"); return }
        await handle.settle()
        #expect(transport.requestCount == 2)
        #expect(!handle.isStale)
        withExtendedLifetime(retention) {}
    }

    @Test("an expired handle refetches on attach under storeOrNetwork")
    func expiration() async {
        let transport = transport()
        let environment = Environment(transport: transport, store: Store(cacheExpiration: .zero))
        let handle = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let retention = handle.retain()
        await handle.settle()
        #expect(transport.requestCount == 1)
        #expect(handle.isStale)

        _ = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        await handle.settle()
        #expect(transport.requestCount == 2)
        withExtendedLifetime(retention) {}
    }

    /// A transport that serves a character's header for a lookup by id,
    /// whichever operation asks.
    func characterTransport() -> RecordedTransport {
        RecordedTransport { request in
            guard case .string(let id)? = request.variables["id"] else { return nil }
            return fixture("character-header-\(id)")
        }
    }

    @Test("an operation's own cache expiration is the constant its directive states, and an operation without the directive has none")
    func cacheExpirationIsGenerated() {
        #expect(TestFreshCharacter.cacheExpiration == .seconds(30))
        #expect(TestHeaderQuery.cacheExpiration == nil)
    }

    @Test("an operation's own cache expiration outranks the store's default: with a default of zero, only the operation without a directive is stale after its fetch")
    func operationExpirationOutranksTheStoreDefault() async {
        let environment = Environment(transport: characterTransport(), store: Store(cacheExpiration: .zero))
        let header = environment.handle(for: TestHeaderQuery(id: "5"))
        let fresh = environment.handle(for: TestFreshCharacter(id: "5"))
        let headerRetention = header.retain()
        let freshRetention = fresh.retain()
        await header.settle()
        await fresh.settle()
        guard case .ready = header.phase, case .ready = fresh.phase else {
            Issue.record("expected both ready, got \(header.phase) and \(fresh.phase)")
            return
        }
        #expect(header.isStale, "the store's default of zero ages it at once")
        #expect(!fresh.isStale, "thirty seconds of its own outrank the store's default")

        environment.invalidate()
        #expect(header.isStale)
        #expect(fresh.isStale, "an invalidation ages data whatever its expiration")
        withExtendedLifetime((headerRetention, freshRetention)) {}
    }

    @Test("with no default in the store, neither an operation without a directive nor one with it is stale after its fetch, and an invalidation ages both")
    func noStoreDefaultKeepsDataFresh() async {
        let environment = Environment(transport: characterTransport())
        let header = environment.handle(for: TestHeaderQuery(id: "5"))
        let fresh = environment.handle(for: TestFreshCharacter(id: "5"))
        let headerRetention = header.retain()
        let freshRetention = fresh.retain()
        await header.settle()
        await fresh.settle()
        guard case .ready = header.phase, case .ready = fresh.phase else {
            Issue.record("expected both ready, got \(header.phase) and \(fresh.phase)")
            return
        }
        #expect(!header.isStale)
        #expect(!fresh.isStale)

        environment.invalidate()
        #expect(header.isStale)
        #expect(fresh.isStale)
        withExtendedLifetime((headerRetention, freshRetention)) {}
    }

    @Test("every server write dates its operation, whoever asked for it: a handle's fetch, a fetch by type and variables, and a payload committed by hand")
    func everyServerWriteDatesItsOperation() async throws {
        // An expiration applies, so data with no known age would read stale.
        let environment = Environment(transport: transport(), store: Store(cacheExpiration: .seconds(3600)))
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        #expect(handle.fetchTime == nil)
        await handle.settle()
        #expect(handle.fetchTime != nil, "the handle's fetch dated its operation")
        #expect(!handle.isStale)

        let beforeFetch = environment.store.rootCount
        try await environment.fetch(TestHeaderQuery.self, variables: TestHeaderQuery(id: "11").variables)
        #expect(environment.store.rootCount == beforeFetch + 1, "the query written that nothing retains waits in the release buffer")
        let fetched = environment.handle(for: TestHeaderQuery(id: "11"), fetchPolicy: .storeOnly)
        guard case .ready = fetched.phase else {
            Issue.record("expected the fetched lookup from the store, got \(fetched.phase)")
            return
        }
        #expect(fetched.fetchTime != nil, "the fetch by type dated the operation no handle asked for")
        #expect(!fetched.isStale)

        let beforeCommit = environment.store.rootCount
        try await environment.commitPayload(Fixture(page: 1), fixtureData)
        #expect(environment.store.rootCount == beforeCommit + 1, "the query committed by hand waits in the release buffer")
        let committed = environment.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        guard case .ready = committed.phase else {
            Issue.record("expected the committed page from the store, got \(committed.phase)")
            return
        }
        #expect(committed.fetchTime != nil, "the payload committed by hand dated its operation")
        #expect(!committed.isStale)
        withExtendedLifetime(retention) {}
    }

    @Test("data no fetch of its own operation dated is stale where an expiration applies, and fresh where none does")
    func dataWithNoKnownAgeIsStaleUnderAnExpiration() async throws {
        for expiration in [Duration.seconds(3600), nil] {
            let environment = Environment(transport: transport(), store: Store(cacheExpiration: expiration))
            let list = environment.handle(for: TestList(page: 1))
            let retention = list.retain()
            await list.settle()
            // The list brought the character; its lookup was never fetched.
            let header = environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly)
            guard case .ready = header.phase else {
                Issue.record("expected the lookup answered by the list, got \(header.phase)")
                return
            }
            #expect(header.fetchTime == nil)
            #expect(header.isStale == (expiration != nil))
            withExtendedLifetime(retention) {}
        }
    }

    @Test("a refetch during a fetch supersedes it: one fetch stays in flight, the superseded response is not committed, and the handle follows the refetch")
    func refetchDuringAFetch() async throws {
        let transport = GatedTransport()
        let environment = Environment(transport: transport)
        let store = environment.store
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let morty = TestRow_character(anchor: Anchor(record: try #require(store.existing("Character:2")), variables: .none, store: store))

        // Ready from the store, with the attach's fetch in flight.
        let handle = environment.handle(for: TestList(page: 1), fetchPolicy: .storeAndNetwork)
        let retention = handle.retain()
        await until { transport.pending >= 1 }
        #expect(handle.isRefreshing)

        let refetch = Task { try await handle.refetch() }
        await until { transport.pending >= 2 }

        // The superseded fetch answers; this transport does not hear the
        // cancellation. Its response is not committed: the handle follows the
        // refetch alone.
        let renamed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        transport.respond(Data(renamed.utf8))
        // Long past the few milliseconds the response takes to read: had it
        // been committed, it would be in the store by now.
        try await Task.sleep(for: .milliseconds(200))
        #expect(morty.name == "Morty Smith", "the superseded response did not land")
        #expect(handle.isRefreshing, "the refetch is still in flight")

        // Another attach finds that fetch and starts none of its own.
        _ = environment.handle(for: TestList(page: 1), fetchPolicy: .storeAndNetwork)
        for _ in 0..<100 { await Task.yield() }
        #expect(transport.pending == 1)

        let refetched = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty Prime\"")
        transport.respond(Data(refetched.utf8))
        try await refetch.value
        #expect(!handle.isRefreshing)
        #expect(transport.pending == 0)
        #expect(morty.name == "Morty Prime", "the refetch's response did")
        withExtendedLifetime(retention) {}
    }

    /// A transport whose streams deliver the parts a test hands them, each
    /// stream in the order it was asked for.
    final class ManualStreams: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [AsyncThrowingStream<Data, any Error>.Continuation] = []

        var count: Int { lock.withLock { streams.count } }

        func execute(_ request: Request) async throws -> Data { throw TransportError(statusCode: 0, body: "streams only") }

        func stream(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            lock.withLock { streams.append(continuation) }
            return stream
        }

        func deliver(_ part: Data, to index: Int) {
            _ = lock.withLock { streams[index] }.yield(part)
        }
    }

    @Test("a deferred fetch a refetch superseded commits neither the first part nor a later one it had in hand")
    func supersededDeferredParts() async throws {
        for afterFirstPart in [false, true] {
            let transport = ManualStreams()
            let environment = Environment(transport: transport)
            environment.store.reportMissing = nil
            let handle = environment.handle(for: TestProfileQuery(id: "1"))
            let retention = handle.retain()
            await until { transport.count == 1 }
            if afterFirstPart {
                transport.deliver(fixture("character-deferred-1"), to: 0)
                await until { if case .loading = handle.phase { false } else { true } }
            }
            // The parts are in the stream's hands when the refetch, in the
            // same turn of the main actor, cancels its fetch.
            if !afterFirstPart { transport.deliver(fixture("character-deferred-1"), to: 0) }
            transport.deliver(fixture("character-deferred-2"), to: 0)
            let refetch = Task { try await handle.refetch() }
            await until { transport.count == 2 }
            try await Task.sleep(for: .milliseconds(200))
            #expect(environment.store.existing("Episode:2") == nil, "the superseded later part did not land")
            if !afterFirstPart {
                #expect(environment.store.existing("Character:1") == nil, "the superseded first part did not land")
            }
            refetch.cancel()
            _ = consume retention
        }
    }

    @Test("a refetch that changes nothing re-runs no body that reads the phase, and one that fails throws while the data stays")
    func phaseChangesOnlyWhenItChanges() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 3 ? nil : fixtureData }
        let environment = Environment(transport: transport)
        let handle = environment.handle(for: TestList(page: 1))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready = handle.phase else { Issue.record("expected ready, got \(handle.phase)"); return }

        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking { _ = handle.phase } onChange: { counter.fired += 1 }
        try await handle.refetch()
        #expect(counter.fired == 0, "ready again over the same root is no change")

        await #expect(throws: TransportError.self) { try await handle.refetch() }
        #expect(counter.fired == 0)
        guard case .ready = handle.phase else { Issue.record("the data stays visible, got \(handle.phase)"); return }
        #expect(!handle.isRefreshing)
        withExtendedLifetime(retention) {}
    }

    @Test("networkOnly does not send a handle someone shows back to loading, and does not read the store to decide")
    func networkOnlyOnAShownHandle() async throws {
        let transport = transport()
        let environment = Environment(transport: transport)
        let shown = environment.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        let shownRetention = shown.retain()
        await shown.settle()
        guard case .ready = shown.phase else { Issue.record("expected ready, got \(shown.phase)"); return }
        let again = environment.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        #expect(again === shown)
        guard case .ready = again.phase else { Issue.record("a second view's attach left the first one's data, got \(again.phase)"); return }
        await again.settle()
        #expect(transport.requestCount == 2)
        withExtendedLifetime(shownRetention) {}
    }

    @Test("collection keeps what a retained handle reads under a type condition")
    func collectionFollowsTheVariant() async throws {
        let environment = Environment(transport: RecordedTransport([TestSearchOrigins.name: fixture("search-origins-1")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestSearchOrigins(name: "a"))
        let retention = handle.retain()
        await handle.settle()
        #expect(environment.store.existing("Location:1") != nil)
        environment.store.collect()
        #expect(environment.store.existing("Location:1") != nil, "Rick's origin is read through `... on Character`")
        _ = consume retention
    }

    @Test("a preload's fetch serves the first attach, in flight or done")
    func preloadServesTheFirstAttach() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        let preloaded = environment.preload(TestList(page: 1), fetchPolicy: .storeAndNetwork)
        await preloaded.settle()
        let attached = environment.handle(for: TestList(page: 1), fetchPolicy: .storeAndNetwork)
        #expect(attached === preloaded)
        await attached.settle()
        #expect(transport.requestCount == 1, "the attach after a finished preload makes no request")
        _ = environment.handle(for: TestList(page: 1), fetchPolicy: .storeAndNetwork)
        await attached.settle()
        #expect(transport.requestCount == 2, "the next attach follows its policy")
    }

    @Test("a preloaded operation is waiting in the buffer when the view attaches")
    func preload() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        let preloaded = environment.preload(TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(environment.store.rootCount == 1)
        await preloaded.settle()

        let attached = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(attached === preloaded)
        guard case .ready = attached.phase else { Issue.record("expected ready"); return }
        #expect(transport.requestCount == 1)
    }

    @Test("retry after a failure fetches again and the handle becomes ready")
    func retry() async {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 1 ? nil : fixtureData }
        let environment = Environment(transport: transport)
        let handle = environment.handle(for: TestList(page: 1))
        let retention = handle.retain()
        await handle.settle()
        guard case .failed = handle.phase else { Issue.record("expected the first fetch to fail, got \(handle.phase)"); return }

        handle.retry()
        guard case .loading = handle.phase else { Issue.record("a retry shows loading, got \(handle.phase)"); return }
        await handle.settle()
        guard case .ready(let data) = handle.phase else { Issue.record("expected ready after the retry, got \(handle.phase)"); return }
        #expect(data.characters?.results?.first?.testRow.name == "Rick Sanchez")
        #expect(transport.requestCount == 2)
        withExtendedLifetime(retention) {}
    }

    @Test("a view's storage retains its handle while the view lives and releases it when the view goes away")
    func storageLifetime() async throws {
        let environment = Environment(transport: SilentTransport(), store: Store(releaseBufferSize: 0))
        environment.store.reportMissing = nil
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        // The renderer installs the view's state, runs the storage's update
        // and draws once; the pool lets its view graph go when it ends.
        var held: OperationHandle<TestHeaderQuery>?
        autoreleasepool {
            let probe = StorageProbe(storage: OperationStorage(TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly))
            let renderer = ImageRenderer(content: probe.environment(\.baton, environment))
            #expect(renderer.cgImage != nil)
            held = environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly)
            #expect(held?.retainCount == 1, "the storage retained the handle it resolved")
        }

        let handle = try #require(held)
        guard case .ready = handle.phase else { Issue.record("expected ready from the store, got \(handle.phase)"); return }
        await until { handle.retainCount == 0 }
        #expect(environment.store.rootCount == 0, "released with an empty buffer, the handle is no root")
    }

    @Test("a subscription value reaches the handle the storage that resolved it holds, a bare value reaches none, and the stream closes when the view goes away")
    func subscriptionResolution() async throws {
        final class Seen: @unchecked Sendable { var handle: SubscriptionHandle<TestNoteAdded>? }
        struct Probe: View {
            let storage: SubscriptionStorage<TestNoteAdded>
            let seen: Seen
            var body: some View {
                seen.handle = storage.resolved.subscription
                return Text("probe")
            }
        }
        let environment = Baton.Environment(transport: SilentTransport(), subscriptions: DeliveryTests.Events())
        let value = TestNoteAdded(characterId: "resolution", connections: [])
        #expect(value.subscription == nil)
        let seen = Seen()
        autoreleasepool {
            let renderer = ImageRenderer(content: Probe(storage: SubscriptionStorage(value), seen: seen).environment(\.baton, environment))
            #expect(renderer.cgImage != nil)
            #expect(seen.handle === environment.subscriptionHandle(for: value))
            #expect(seen.handle?.isActive == true, "the storage opened the stream")
        }
        #expect(value.subscription == nil, "the value itself holds nothing")
        let handle = try #require(seen.handle)
        await until { !handle.isActive }
        #expect(handle.retainCount == 0, "the storage released the handle when the view went away")
    }

    @Test("a handle whose environment is gone keeps its data and stops loading instead of hanging")
    func handleAfterTheEnvironment() async throws {
        var environment: Baton.Environment? = Baton.Environment(transport: SilentTransport())
        environment!.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let ready = environment!.handle(for: TestList(page: 1), fetchPolicy: .storeOnly)
        let empty = environment!.handle(for: TestList(page: 2), fetchPolicy: .storeOnly)
        let subscription = environment!.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
        let readyRetention = ready.retain()
        let emptyRetention = empty.retain()
        environment = nil

        try await ready.refetch()
        #expect(!ready.isRefreshing)
        guard case .ready = ready.phase else { Issue.record("the data stays visible, got \(ready.phase)"); return }
        try await ready.refetch()
        #expect(!ready.isRefreshing, "a second refetch does not hang either")

        empty.retry()
        guard case .failed(let error as EnvironmentError) = empty.phase, error == .gone else {
            Issue.record("a retry with nothing to fetch with fails on the environment it lost, got \(empty.phase)")
            return
        }

        let subscriptionRetention = subscription.retain()
        #expect(!subscription.isActive, "no stream opens without an environment")
        _ = consume subscriptionRetention
        _ = consume readyRetention
        _ = consume emptyRetention
    }

    @Test("a request with nothing to send it fails on what is missing: the view's environment, the lens's, or the subscription transport")
    func nothingToSendWith() async throws {
        let unconfigured = Environment.resolve(nil).handle(for: TestList(page: 404))
        await unconfigured.settle()
        guard case .failed(let error as EnvironmentError) = unconfigured.phase, error == .notInjected else {
            Issue.record("expected the missing environment, got \(unconfigured.phase)")
            return
        }

        let store = Store()
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let character = try #require(store.existing("Character:1"))
        let notes = TestNotes_character(anchor: Anchor(record: character, variables: TestNotesQuery(id: "1").variables, store: store))
        await #expect(throws: EnvironmentError.outsideEnvironment) { try await notes.refetch() }

        let environment = Baton.Environment(transport: SilentTransport())
        let subscription = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
        let subscriptionRetention = subscription.retain()
        await until { !subscription.isActive }
        #expect(subscription.error as? EnvironmentError == .noSubscriptionTransport)
        _ = consume subscriptionRetention
    }

    @Test("a view whose environment is replaced resolves its operation again in the new one")
    func storageFollowsTheEnvironment() async throws {
        func environment() throws -> Baton.Environment {
            let environment = Baton.Environment(transport: SilentTransport(), store: Store(releaseBufferSize: 0))
            environment.store.reportMissing = nil
            environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
            return environment
        }
        let first = try environment()
        let second = try environment()
        let probe = StorageProbe(storage: OperationStorage(TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly))
        autoreleasepool {
            let renderer = ImageRenderer(content: AnyView(probe.environment(\.baton, first)))
            #expect(renderer.cgImage != nil)
            renderer.content = AnyView(probe.environment(\.baton, second))
            #expect(renderer.cgImage != nil)
            #expect(second.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly).retainCount == 1, "the new environment's handle is retained")
        }
        #expect(first.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly).retainCount == 0, "the old one's was released")
    }

    @Test("a handle released after its environment is gone does nothing")
    func releaseAfterTheEnvironment() {
        var environment: Baton.Environment? = Baton.Environment(transport: SilentTransport())
        let handle = environment!.handle(for: TestList(page: 1), fetchPolicy: .storeOnly)
        let subscription = environment!.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
        let retention = handle.retain()
        let subscriptionRetention = subscription.retain()
        environment = nil
        _ = consume retention
        _ = consume subscriptionRetention
        #expect(handle.retainCount == 0)
        #expect(!subscription.isActive)
    }

    /// Lets the main actor turn often enough for a pass scheduled before to
    /// have run.
    func turns() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("a screen that stays up and refetches has what its new response no longer reaches collected, with no release")
    func aRefetchThatDropsLinksIsCollected() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 1 ? fixtureData : shiftedFixture(by: 100_000) }
        let environment = Environment(transport: transport)
        let store = environment.store
        let handle = environment.handle(for: TestList(page: 1))
        let retention = handle.retain()
        await handle.settle()
        await turns()
        #expect(store.existing("Character:1") != nil)
        let collections = store.collections

        // The same page answers with other characters: the list's links move
        // off the first twenty, and nothing else reaches them.
        try await handle.refetch()
        #expect(store.existing("Character:100001") != nil)
        await until { store.collections > collections }
        #expect(store.collections == collections + 1, "one pass for the commit")
        #expect(store.existing("Character:1") == nil, "the records the list dropped are collected")
        #expect(store.existing("Character:100001") != nil, "the records it reaches now stay")
        #expect(handle.retainCount == 1, "nothing was released")
        guard case .ready(let data) = handle.phase else { Issue.record("expected ready, got \(handle.phase)"); return }
        #expect(data.characters?.results?.count == 20)
        withExtendedLifetime(retention) {}
    }

    @Test("a release that only moves a root into the buffer runs no pass, and the records stay")
    func aReleaseIntoTheBufferRunsNoPass() async {
        let environment = Environment(transport: transport(), store: Store(releaseBufferSize: 10))
        let store = environment.store
        let handle = environment.handle(for: TestList(page: 1))
        let retention = handle.retain()
        await handle.settle()
        await turns()
        let collections = store.collections

        _ = consume retention
        await turns()
        #expect(handle.retainCount == 0)
        #expect(store.rootCount == 1, "the root waits in the buffer")
        #expect(store.collections == collections, "no root left, so no pass ran")
        #expect(store.existing("Character:1") != nil)
    }

    @Test("a release that pushes a root out of the buffer runs a pass that sweeps its records")
    func anEvictionRunsAPass() async {
        let environment = Environment(transport: transport(), store: Store(releaseBufferSize: 0))
        let store = environment.store
        let handle = environment.handle(for: TestList(page: 1))
        let retention = handle.retain()
        await handle.settle()
        await turns()
        #expect(store.existing("Character:1") != nil)
        let collections = store.collections

        _ = consume retention
        await until { store.collections > collections }
        #expect(store.rootCount == 0)
        #expect(store.existing("Character:1") == nil, "the evicted root's records are swept")
    }

    @Test("a model that holds a retention releases its operation when it goes away")
    func aModelsRetentionEndsWithIt() async throws {
        let environment = Environment(transport: transport(), store: Store(releaseBufferSize: 0))
        let store = environment.store
        var model: CharactersModel? = CharactersModel(environment: environment)
        let handle = try #require(model?.handle)
        await handle.settle()
        await turns()
        #expect(model?.firstName == "Rick Sanchez")
        #expect(handle.retainCount == 1)
        let collections = store.collections

        model = nil
        await until { store.collections > collections }
        #expect(handle.retainCount == 0)
        #expect(store.existing("Character:1") == nil, "with an empty buffer, the model's records are swept")
    }

    @Test("a retention released at the end of its scope releases its operation")
    func aRetentionEndsWithItsScope() async {
        let environment = Environment(transport: transport(), store: Store(releaseBufferSize: 0))
        let store = environment.store
        let handle = environment.handle(for: TestList(page: 1))
        let collections: Int
        do {
            let retention = handle.retain()
            await handle.settle()
            await turns()
            #expect(handle.retainCount == 1)
            #expect(store.existing("Character:1") != nil)
            collections = store.collections
            withExtendedLifetime(retention) {}
        }
        await until { store.collections > collections }
        #expect(handle.retainCount == 0)
        #expect(store.existing("Character:1") == nil, "with an empty buffer, the records are swept")
    }

    @Test("a subscription retained again after its release closes its stream at the next release")
    func aSubscriptionRetainedAgainClosesAtItsNextRelease() {
        let events = DeliveryTests.Events()
        let environment = Baton.Environment(transport: SilentTransport(), subscriptions: events)
        environment.store.reportMissing = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "lifetime-\(#line)", connections: []))
        for _ in 0..<2 {
            do {
                let retention = live.retain()
                #expect(live.isActive)
                #expect(live.retainCount == 1)
                withExtendedLifetime(retention) {}
            }
            #expect(!live.isActive, "the release closed the stream")
            #expect(live.retainCount == 0)
        }
    }
}
