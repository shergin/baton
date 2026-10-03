import Baton
import Foundation
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

@MainActor
@Suite("Lifetime")
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

    @Test("a refetch during a fetch supersedes it: one fetch stays in flight and the handle follows it", .timeLimit(.minutes(1)))
    func refetchDuringAFetch() async throws {
        let transport = GatedTransport()
        let environment = Environment(transport: transport)
        let store = environment.store
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let morty = TestRow_character(anchor: Anchor(record: try #require(store.existing("Character:2")), variables: .none, store: store))

        // Ready from the store, with the attach's fetch in flight.
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
        while transport.pending < 1 { await Task.yield() }
        #expect(handle.isRefreshing)

        let refetch = Task { await handle.refetch() }
        while transport.pending < 2 { await Task.yield() }

        // The superseded fetch answers; this transport does not hear the
        // cancellation. The handle keeps following the refetch.
        let renamed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        transport.respond(Data(renamed.utf8))
        while morty.name != "Morty C-137" { await Task.yield() }
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
}
