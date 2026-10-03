import Baton
import Foundation
import Observation
import Testing

/// The recorded response for `Fixture(page: 1)`.
let fixtureData: Data = {
    let url = Bundle.module.url(forResource: "characters-page-1", withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}()

@MainActor
@Suite("The vertical spine")
struct SpineTests {
    @Test("ingesting the fixture and reading it through lenses agrees with the raw response")
    func theResponseIsTheOracle() throws {
        let store = Store()
        let variables = Fixture(page: 1).variables
        let changes = try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(variables))
        let changed = store.commit(changes)

        let tree = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        let rawResults = ((tree["data"] as! [String: Any])["characters"] as! [String: Any])["results"] as! [[String: Any]]

        #expect(store.count == 901, "898 entities and three roots")
        #expect(changed > 0)
        let data = Fixture.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let results = try #require(data.characters?.results)
        #expect(results.count == rawResults.count)
        for (lens, raw) in zip(results, rawResults) {
            #expect(lens.name == raw["name"] as? String)
            #expect(lens.image == raw["image"] as? String)
            #expect(lens.origin?.name == (raw["origin"] as? [String: Any])?["name"] as? String)
            #expect(lens.episode.count == (raw["episode"] as! [Any]).count)
        }
        #expect(data.characters?.info?.count == 826)
        #expect(data.characters?.info?.prev == nil)

        // The same entity reached by two paths is one record.
        let rick = results[0]
        let rickViaEpisode = try #require(results[0].episode.first?.characters.first { $0.name == "Rick Sanchez" })
        #expect(rick.recordID == rickViaEpisode.recordID)
    }

    @Test("a character already in the store renders in the first body of its detail")
    func firstBodyFromCache() throws {
        let environment = Environment(transport: SilentTransport())
        let listVariables = TestList(page: 1).variables
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(listVariables)))

        // The detail's root field `character(id: "1")` was never fetched; the
        // lookup satisfies it from the cached entity, synchronously.
        let cached = environment.handle(for: TestHeaderQuery(id: "1"))
        guard case .ready(let data) = cached.phase else {
            Issue.record("expected .ready on creation, got \(cached.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Rick Sanchez")
        #expect(data.character?.testHeader.origin?.name == "Earth (C-137)")
        #expect(cached.isRefreshing, "store-and-network still fetches")

        let absent = environment.handle(for: TestHeaderQuery(id: "999"))
        guard case .loading = absent.phase else {
            Issue.record("expected .loading for an entity the store never saw")
            return
        }
    }

    @Test("a commit that changes one field invalidates exactly one row")
    func oneFieldOneRow() throws {
        let store = Store()
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let rows = try #require(data.characters?.results)
        #expect(rows.count == 20)

        final class Counter: @unchecked Sendable { var fired: [String] = [] }
        let counter = Counter()
        for row in rows {
            let lens = row.testRow
            let key = lens.anchor.record.key
            withObservationTracking {
                _ = lens.name
                _ = lens.status
                _ = lens.image
            } onChange: {
                counter.fired.append(key)
            }
        }

        // Same payload again: nothing changes, nothing fires, nothing allocates for strings.
        let unchanged = store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))
        #expect(unchanged == 0)
        #expect(counter.fired.isEmpty)

        // Morty's name changes in the payload: one record, one row.
        let edited = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let changed = store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestList.plan.resolve(variables)))
        #expect(changed == 1)
        #expect(counter.fired == ["Character:2"])
        #expect(rows[1].testRow.name == "Morty C-137")
    }

    @Test("a lens read of a root field falls through to the cached entity")
    func lookupOnRead() throws {
        let store = Store()
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))

        let detail = TestHeaderQuery(id: "3")
        let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: detail.variables, store: store))
        #expect(data.character?.testHeader.name == "Summer Smith")
        // The link is now written, so the plan checks as available.
        #expect(store.check(TestHeaderQuery.plan.resolve(detail.variables)))
    }

    @Test("operation values hash by their variables only")
    func operationValueIdentity() {
        let a = TestHeaderQuery(id: "1")
        var b = TestHeaderQuery(id: "1")
        b.resolution = nil
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(TestHeaderQuery(id: "2") != a)
        #expect(TestHeaderQuery.persistedID.count == 32)
    }
}
