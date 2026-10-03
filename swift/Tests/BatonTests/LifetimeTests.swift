import Baton
import Foundation
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

    @Test("a refetch during a fetch supersedes it: one fetch stays in flight and the handle follows it")
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

        let refetch = Task { await handle.refetch() }
        await until { transport.pending >= 2 }

        // The superseded fetch answers; this transport does not hear the
        // cancellation. The handle keeps following the refetch.
        let renamed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        transport.respond(Data(renamed.utf8))
        await until { morty.name == "Morty C-137" }
        #expect(handle.isRefreshing, "the refetch is still in flight")

        // Another attach finds that fetch and starts none of its own.
        _ = environment.handle(for: TestList(page: 1))
        for _ in 0..<100 { await Task.yield() }
        #expect(transport.pending == 1)

        transport.respond(fixtureData)
        await refetch.value
        #expect(!handle.isRefreshing)
        #expect(transport.pending == 0)
        #expect(morty.name == "Morty Smith")
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

        await ready.refetch()
        #expect(!ready.isRefreshing)
        guard case .ready = ready.phase else { Issue.record("the data stays visible, got \(ready.phase)"); return }
        await ready.refetch()
        #expect(!ready.isRefreshing, "a second refetch does not hang either")

        empty.retry()
        guard case .failed = empty.phase else { Issue.record("a retry with nothing to fetch with fails, got \(empty.phase)"); return }

        subscription.retain()
        #expect(!subscription.isActive, "no stream opens without an environment")
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
