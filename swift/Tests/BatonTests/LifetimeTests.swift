import Baton
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

@MainActor
@Suite("Lifetime", .timeLimit(.minutes(1)))
struct LifetimeTests {
    /// A transport that serves the fixture for any page, shifted by page number.
    func transport() -> RecordedTransport {
        RecordedTransport { request in
            guard case .int(let page)? = request.variables["page"] else { return fixtureData }
            return page == 1 ? fixtureData : shiftedFixture(by: page * 100_000)
        }
    }

    @Test("a screen left and re-entered within the buffer makes no request")
    func reentryWithinTheBuffer() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        environment.releaseBufferSize = 2

        let first = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        first.retain()
        await first.settle()
        #expect(transport.requestCount == 1)
        first.release()

        // Back within the buffer: same handle, complete and fresh, no request.
        let again = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(again === first)
        guard case .ready = again.phase else { Issue.record("expected ready"); return }
        #expect(transport.requestCount == 1)
        again.retain()
        again.release()

        // Two more released handles push it out of a buffer of two.
        for page in 2...3 {
            let other = environment.handle(for: TestList(page: page), fetchPolicy: .storeOrNetwork)
            other.retain()
            await other.settle()
            other.release()
        }
        // Eviction schedules a collection; once it has run, page 1 is gone from
        // the store and the next attach must fetch again.
        environment.collect()
        #expect(environment.store.existing("Character:1") == nil)
        let evicted = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(evicted !== first)
        await evicted.settle()
        #expect(transport.requestCount == 4, "pages 1, 2, 3, then 1 again after eviction")
    }

    @Test("collection removes records no root reaches and keeps shared ones")
    func collection() async {
        let environment = Environment(transport: transport())
        environment.releaseBufferSize = 0

        let page1 = environment.handle(for: TestList(page: 1))
        page1.retain()
        await page1.settle()
        // The list plan stores what it selects: 20 characters and their origins.
        let afterPage1 = environment.store.count
        #expect(afterPage1 > 20)

        let page2 = environment.handle(for: TestList(page: 2))
        page2.retain()
        await page2.settle()
        #expect(environment.store.count > afterPage1)

        // Releasing page 2 with an empty buffer evicts it; collection follows.
        page2.release()
        let removed = environment.collect()
        #expect(removed > 0)
        #expect(environment.store.count == afterPage1)
        #expect(environment.store.existing("Character:1") != nil)
        #expect(environment.store.existing("Character:200001") == nil)

        // The retained page still reads.
        guard case .ready(let data) = page1.phase else { Issue.record("page 1 should stay ready"); return }
        #expect(data.characters?.results?.first?.testRow.name == "Rick Sanchez")
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

        let eager = environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeAndNetwork)
        guard case .ready = eager.phase else { Issue.record("expected ready from the lookup"); return }
        #expect(eager.isRefreshing)
        await eager.settle()
        #expect(transport.requestCount == 1)

        let networkOnly = environment.handle(for: TestHeaderQuery(id: "2"), fetchPolicy: .networkOnly)
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
        handle.retain()
        await handle.settle()
        #expect(transport.requestCount == 1)
        #expect(!handle.isStale)

        environment.invalidate()
        #expect(handle.isStale)
        guard case .ready = handle.phase else { Issue.record("data stays visible while stale"); return }
        await handle.settle()
        #expect(transport.requestCount == 2)
        #expect(!handle.isStale)
    }

    @Test("an expired handle refetches on attach under storeOrNetwork")
    func expiration() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        environment.queryCacheExpiration = .zero
        let handle = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        handle.retain()
        await handle.settle()
        #expect(transport.requestCount == 1)
        #expect(handle.isStale)

        _ = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        await handle.settle()
        #expect(transport.requestCount == 2)
    }

    @Test("a refetch during a fetch supersedes it: one fetch stays in flight, the superseded response is not committed, and the handle follows the refetch")
    func refetchDuringAFetch() async throws {
        let transport = GatedTransport()
        let environment = Environment(transport: transport)
        let store = environment.store
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let morty = TestRow_character(anchor: Anchor(record: try #require(store.existing("Character:2")), variables: .none, store: store))

        // Ready from the store, with the attach's fetch in flight.
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
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
        _ = environment.handle(for: TestList(page: 1))
        for _ in 0..<100 { await Task.yield() }
        #expect(transport.pending == 1)

        let refetched = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty Prime\"")
        transport.respond(Data(refetched.utf8))
        try await refetch.value
        #expect(!handle.isRefreshing)
        #expect(transport.pending == 0)
        #expect(morty.name == "Morty Prime", "the refetch's response did")
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
            handle.retain()
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
            handle.release()
        }
    }

    @Test("a refetch that changes nothing re-runs no body that reads the phase, and one that fails throws while the data stays")
    func phaseChangesOnlyWhenItChanges() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 3 ? nil : fixtureData }
        let environment = Environment(transport: transport)
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
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
    }

    @Test("networkOnly does not send a handle someone shows back to loading, and does not read the store to decide")
    func networkOnlyOnAShownHandle() async throws {
        let transport = transport()
        let environment = Environment(transport: transport)
        let shown = environment.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        shown.retain()
        await shown.settle()
        guard case .ready = shown.phase else { Issue.record("expected ready, got \(shown.phase)"); return }
        let again = environment.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        #expect(again === shown)
        guard case .ready = again.phase else { Issue.record("a second view's attach left the first one's data, got \(again.phase)"); return }
        await again.settle()
        #expect(transport.requestCount == 2)
    }

    @Test("collection keeps what a retained handle reads under a type condition")
    func collectionFollowsTheVariant() async throws {
        let environment = Environment(transport: RecordedTransport([TestSearchOrigins.name: fixture("search-origins-1")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestSearchOrigins(name: "a"))
        handle.retain()
        await handle.settle()
        #expect(environment.store.existing("Location:1") != nil)
        environment.collect()
        #expect(environment.store.existing("Location:1") != nil, "Rick's origin is read through `... on Character`")
        handle.release()
    }

    @Test("a preload's fetch serves the first attach, in flight or done")
    func preloadServesTheFirstAttach() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        let preloaded = environment.preload(TestList(page: 1))
        await preloaded.settle()
        let attached = environment.handle(for: TestList(page: 1))
        #expect(attached === preloaded)
        await attached.settle()
        #expect(transport.requestCount == 1, "the attach after a finished preload makes no request")
        _ = environment.handle(for: TestList(page: 1))
        await attached.settle()
        #expect(transport.requestCount == 2, "the next attach follows its policy")
    }

    @Test("a preloaded operation is waiting in the buffer when the view attaches")
    func preload() async {
        let transport = transport()
        let environment = Environment(transport: transport)
        let preloaded = environment.preload(TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(environment.rootCount == 1)
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
        handle.retain()
        await handle.settle()
        guard case .failed = handle.phase else { Issue.record("expected the first fetch to fail, got \(handle.phase)"); return }

        handle.retry()
        guard case .loading = handle.phase else { Issue.record("a retry shows loading, got \(handle.phase)"); return }
        await handle.settle()
        guard case .ready(let data) = handle.phase else { Issue.record("expected ready after the retry, got \(handle.phase)"); return }
        #expect(data.characters?.results?.first?.testRow.name == "Rick Sanchez")
        #expect(transport.requestCount == 2)
    }

    @Test("a view's storage retains its handle while the view lives and releases it when the view goes away")
    func storageLifetime() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.releaseBufferSize = 0
        environment.store.reportMissing = nil
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        // The renderer installs the view's state, runs the storage's update
        // and draws once; the pool lets its view graph go when it ends.
        autoreleasepool {
            let probe = StorageProbe(storage: OperationStorage(TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly))
            let renderer = ImageRenderer(content: probe.environment(\.baton, environment))
            #expect(renderer.cgImage != nil)
            #expect(environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly).retainCount == 1, "the storage retained the handle it resolved")
        }

        let handle = environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly)
        guard case .ready = handle.phase else { Issue.record("expected ready from the store, got \(handle.phase)"); return }
        await until { handle.retainCount == 0 }
        #expect(environment.rootCount == 0, "released with an empty buffer, the handle is no root")
    }

    @Test("a subscription value reaches the handle the storage that resolved it holds, and a bare value reaches none")
    func subscriptionResolution() {
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
        }
        #expect(seen.handle === environment.subscriptionHandle(for: value))
        #expect(value.subscription == nil, "the value itself holds nothing")
    }

    @Test("a handle whose environment is gone keeps its data and stops loading instead of hanging")
    func handleAfterTheEnvironment() async throws {
        var environment: Baton.Environment? = Baton.Environment(transport: SilentTransport())
        environment!.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let ready = environment!.handle(for: TestList(page: 1), fetchPolicy: .storeOnly)
        let empty = environment!.handle(for: TestList(page: 2), fetchPolicy: .storeOnly)
        let subscription = environment!.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
        ready.retain()
        empty.retain()
        environment = nil

        try await ready.refetch()
        #expect(!ready.isRefreshing)
        guard case .ready = ready.phase else { Issue.record("the data stays visible, got \(ready.phase)"); return }
        try await ready.refetch()
        #expect(!ready.isRefreshing, "a second refetch does not hang either")

        empty.retry()
        guard case .failed = empty.phase else { Issue.record("a retry with nothing to fetch with fails, got \(empty.phase)"); return }

        subscription.retain()
        #expect(!subscription.isActive, "no stream opens without an environment")
        subscription.release()
        ready.release()
        empty.release()
    }

    @Test("a view whose environment is replaced resolves its operation again in the new one")
    func storageFollowsTheEnvironment() async throws {
        func environment() throws -> Baton.Environment {
            let environment = Baton.Environment(transport: SilentTransport())
            environment.releaseBufferSize = 0
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
        handle.retain()
        subscription.retain()
        environment = nil
        handle.release()
        subscription.release()
        #expect(handle.retainCount == 0)
        #expect(!subscription.isActive)
    }
}
