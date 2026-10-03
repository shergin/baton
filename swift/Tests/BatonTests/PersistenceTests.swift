import Baton
import Foundation
import Observation
import SQLite3
import Testing

/// A file for one test's image, removed with its journal when the test ends.
final class TemporaryImage {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

/// The store could not answer without the network.
struct NotStored: Error {}

@MainActor
@Suite("Persistence")
struct PersistenceTests {
    let image = TemporaryImage()

    /// An environment over the image, as a launch of the app makes one. A
    /// test runs its launches one after another, as a device does, and ends
    /// each with `finish`.
    func launch(_ transport: any Transport = SilentTransport(), version: String = "") -> Environment {
        let store = Store(persistence: Persistence(url: image.url, version: version))
        store.reportMissing = nil
        return Environment(transport: transport, store: store)
    }

    /// Waits until the launch has written what it owes the image.
    func finish(_ environment: Environment) async {
        await environment.store.persistence?.flush()
    }

    /// Commits the fixture through its own plan and waits for the image.
    func seed(_ environment: Environment) async throws {
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
        await finish(environment)
    }

    /// The data of a handle the store answers without the network.
    func stored<Op: Baton.Operation>(_ operation: Op, in environment: Environment) throws -> Op.Data {
        let handle = environment.handle(for: operation, fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else { throw NotStored() }
        return data
    }

    @Test("a second launch renders the fixture from the image when its handle is made, with no network, and agrees with the response")
    func theFirstBodyReadsTheImage() async throws {
        try await seed(launch())

        let environment = launch()
        #expect(environment.store.count == 3, "nothing is in memory before a handle asks")
        let data = try stored(Fixture(page: 1), in: environment)
        #expect(environment.store.count == 901, "898 entities and three roots, as the first launch held")
        #expect(environment.store.hydratedRecords == 898)

        let tree = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        let rawResults = ((tree["data"] as! [String: Any])["characters"] as! [String: Any])["results"] as! [[String: Any]]
        let results = try #require(data.characters?.results)
        #expect(results.count == rawResults.count)
        for (lens, raw) in zip(results, rawResults) {
            #expect(lens.name == raw["name"] as? String)
            #expect(lens.image == raw["image"] as? String)
            #expect(lens.created == raw["created"] as? String)
            #expect(lens.origin?.name == (raw["origin"] as? [String: Any])?["name"] as? String)
            #expect(lens.origin?.dimension == (raw["origin"] as? [String: Any])?["dimension"] as? String)
            #expect(lens.episode.count == (raw["episode"] as! [Any]).count)
            #expect(lens.episode.last?.characters.count == ((raw["episode"] as! [[String: Any]]).last?["characters"] as? [Any])?.count)
        }
        #expect(data.characters?.info?.count == 826)
        #expect(data.characters?.info?.prev == nil, "a null survives as a null")

        // One entity reached by two paths is still one record.
        let rick = try #require(results[0].episode.first?.characters.first { $0.name == "Rick Sanchez" })
        #expect(rick.recordID == results[0].recordID)

        // The same question again is answered by memory alone.
        _ = try stored(Fixture(page: 1), in: environment)
        #expect(environment.store.hydratedRecords == 898)
    }

    @Test("a refetch after a launch changes one row, and the next launch reads the change")
    func aRefetchReachesTheImage() async throws {
        try await seed(launch())

        let renamed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let second = launch(RecordedTransport { _ in Data(renamed.utf8) })
        let handle = second.handle(for: Fixture(page: 1))
        handle.retain()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the image's data at once, got \(handle.phase)")
            return
        }
        let morty = try #require(data.characters?.results?[1])
        #expect(morty.name == "Morty Smith")
        #expect(handle.isRefreshing, "store-and-network still fetches")
        await handle.settle()
        #expect(morty.name == "Morty C-137")
        await finish(second)

        let third = try stored(Fixture(page: 1), in: launch())
        #expect(third.characters?.results?[1].name == "Morty C-137")
        #expect(third.characters?.results?[1].image == morty.image)
    }

    @Test("a mutation's answer is in the image and an optimistic response never is")
    func optimisticResponsesStayInMemory() async throws {
        let first = launch()
        try await seed(first)
        let rename = TestRename(id: "1", name: "Rick Prime")
        let optimistic = TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable
        let json = Data(("{\"data\":" + optimistic.json + "}").utf8)
        _ = first.store.applyOptimistic(try Ingest.normalize(json, plan: TestRename.plan.resolve(rename.variables), rootKey: Store.mutationRootKey))
        // A commit under the layer writes the server's values, not the layer's.
        let refreshed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"status\":\"Alive\"", with: "\"status\":\"Busy\"")
        first.store.commit(try Ingest.normalize(Data(refreshed.utf8), plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
        #expect(first.store.existing("Character:1")?.read(Registry.slot(Registry.type("Character"), "name")) == .string("Rick Prime"))
        await finish(first)

        let second = launch()
        let before = try stored(Fixture(page: 1), in: second)
        #expect(before.characters?.results?[0].name == "Rick Sanchez", "the layer was never written")
        #expect(before.characters?.results?[0].status == "Busy", "the commit under it was")
        let answer = fixture("rename-1")
        second.store.commit(try Ingest.normalize(answer, plan: TestRename.plan.resolve(rename.variables), rootKey: Store.mutationRootKey))
        await finish(second)

        let third = try stored(Fixture(page: 1), in: launch())
        #expect(third.characters?.results?[0].name == "Rick Prime")
    }

    @Test("field errors survive a launch: @catch reads the error the first launch received")
    func fieldErrorsSurvive() async throws {
        let first = launch(DeliveryTests.OneResponse(fixture("character-errors")))
        let fetched = first.handle(for: TestProfileQuery(id: "1"))
        fetched.retain()
        await fetched.settle()
        await finish(first)

        let data = try stored(TestProfileQuery(id: "1"), in: launch())
        let character = try #require(data.character?.testProfile)
        #expect(character.name == "Rick Sanchez")
        guard case .failure(let image) = character.image else {
            Issue.record("the image lost the error")
            return
        }
        #expect(image.errors == [FieldError(message: "image service unavailable", path: "character.image")])
        guard case .failure(let location) = character.location else {
            Issue.record("the image lost the error inside location")
            return
        }
        #expect(location.errors.map(\.path) == ["character.location.name"])
    }

    @Test("a connection's merged pages and a deletion survive a launch, and the loading flag does not")
    func connectionsSurvive() async throws {
        let first = launch(ListTests.PagingTransport())
        let fetched = first.handle(for: TestNotesQuery(id: "1"))
        fetched.retain()
        await fetched.settle()
        guard case .ready(let loaded) = fetched.phase, let notes = loaded.character?.testNotes.notes else {
            Issue.record("the first page did not arrive")
            return
        }
        try await notes.loadNext()
        #expect(notes.nodes.count == 4)
        // A removal: the edge leaves the connection, the record is deleted.
        let removal = TestRemoveNote(id: "n2", connections: [notes.connectionID])
        let payload = fixture("remove-note-n2")
        first.store.commit(try Ingest.normalize(payload, plan: TestRemoveNote.plan.resolve(removal.variables), rootKey: Store.mutationRootKey))
        await finish(first)

        let second = launch()
        let data = try stored(TestNotesQuery(id: "1"), in: second)
        let restored = try #require(data.character?.testNotes.notes)
        #expect(restored.nodes.map(\.text) == ["Wubba lubba dub dub", "Get Schwifty", "Avoid the Citadel"])
        #expect(restored.totalCount == 5)
        #expect(restored.hasNext)
        #expect(restored.pageInfo.endCursor == "c4")
        #expect(!restored.isLoadingNext)
        #expect(restored.connectionID == notes.connectionID)
        #expect(second.store.existing("Note:n2")?.deleted == true, "the first page still names the note, and it reads as deleted")
    }

    @Test("an entity the image holds satisfies a lookup: a detail renders from a list an earlier launch fetched")
    func lookupsReadTheImage() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        await finish(first)

        let second = launch()
        let data = try stored(TestHeaderQuery(id: "1"), in: second)
        #expect(data.character?.testHeader.name == "Rick Sanchez")
        #expect(data.character?.testHeader.origin?.name == "Earth (C-137)")
        #expect(second.store.hydratedRecords == 2, "the character and its origin, not the list")
    }

    @Test("data keeps its age across a launch: fresh data is not refetched, expired data is, and an invalidation ages everything")
    func ageSurvives() async throws {
        let transport = RecordedTransport { _ in fixtureData }
        let first = launch(transport)
        let fetched = first.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        fetched.retain()
        await fetched.settle()
        #expect(transport.requestCount == 1)
        await finish(first)

        let second = launch(transport)
        let fresh = second.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        guard case .ready = fresh.phase else {
            Issue.record("expected the image's data, got \(fresh.phase)")
            return
        }
        #expect(fresh.fetchTime != nil, "the age came with the data")
        #expect(!fresh.isStale)
        await fresh.settle()
        #expect(transport.requestCount == 1, "fresh data from the image is not refetched")
        await finish(second)

        let third = launch(transport)
        third.queryCacheExpiration = .zero
        let expired = third.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        expired.retain()
        #expect(expired.isStale)
        await expired.settle()
        #expect(transport.requestCount == 2, "expired data is")
        third.queryCacheExpiration = nil
        #expect(!expired.isStale)
        third.invalidate()
        await expired.settle()
        #expect(transport.requestCount == 3, "a retained handle refetches when everything is invalidated")
        // An invalidation that nothing refetched reaches the next launch.
        expired.release()
        third.invalidate()
        await finish(third)

        let fourth = launch(transport)
        let invalidated = fourth.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(invalidated.isStale, "the invalidation outlived the launch")
        await invalidated.settle()
        #expect(transport.requestCount == 4)
    }

    @Test("data read from the image without a fetch time is stale")
    func undatedDataIsStale() async throws {
        let transport = RecordedTransport { _ in fixtureData }
        let first = launch(transport)
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        await finish(first)

        let second = launch(transport)
        let undated = second.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        guard case .ready = undated.phase else {
            Issue.record("expected the image's data, got \(undated.phase)")
            return
        }
        #expect(undated.isStale)
        await undated.settle()
        #expect(transport.requestCount == 1, "so store-or-network asks the network")
        #expect(!undated.isStale)
    }

    @Test("records the collector swept are read again from the image when a screen comes back")
    func sweptRecordsComeBack() async throws {
        let environment = launch()
        try await seed(environment)
        environment.releaseBufferSize = 0
        let handle = environment.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        handle.retain()
        handle.release()
        #expect(environment.collect() == 898)
        #expect(environment.store.count == 3)

        let data = try stored(Fixture(page: 1), in: environment)
        #expect(environment.store.count == 901)
        #expect(data.characters?.results?.first?.name == "Rick Sanchez")
        #expect(data.characters?.results?.first?.episode.first?.characters.first?.name == "Rick Sanchez")
    }

    @Test("a record that goes a whole launch unread is gone at the next; one that is read stays")
    func generations() async throws {
        try await seed(launch())

        // Read in the second launch: kept for the third.
        let second = launch()
        _ = try stored(Fixture(page: 1), in: second)
        await finish(second)
        let third = launch()
        _ = try stored(Fixture(page: 1), in: third)
        await finish(third)

        // The fourth launch does not read it; the fifth finds nothing.
        await finish(launch())
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }
    }

    @Test("an unreadable image is a miss: garbage, another version and an emptied image start over")
    func unreadableIsAMiss() async throws {
        try Data(repeating: 0x42, count: 8192).write(to: image.url)
        let first = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: first) }
        try await seed(first)
        let second = launch()
        _ = try stored(Fixture(page: 1), in: second)
        await finish(second)

        // Another version of the app's cache: the rows are not read.
        let upgraded = launch(version: "2")
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: upgraded) }
        try await seed(upgraded)

        // A sign-out empties the image; memory keeps what it had.
        let leaving = launch(version: "2")
        _ = try stored(Fixture(page: 1), in: leaving)
        leaving.store.persistence?.removeAll()
        await finish(leaving)
        _ = try stored(Fixture(page: 1), in: leaving)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch(version: "2")) }
    }

    @Test("a database that is not an image is left alone, and the store works without one")
    func foreignDatabase() async throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE notes(text); INSERT INTO notes VALUES('mine')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let environment = launch()
        try await seed(environment)
        _ = try stored(Fixture(page: 1), in: environment)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }

        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "SELECT text FROM notes", nil, nil, nil) == SQLITE_OK, "the table is still there")
        sqlite3_close(db)
    }
}
