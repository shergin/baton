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
@Suite("Persistence", .timeLimit(.minutes(1)))
struct PersistenceTests {
    let image = TemporaryImage()

    /// An environment over the image, as a launch of the app makes one. A
    /// test runs its launches one after another, as a device does, and ends
    /// each with `finish`.
    func launch(_ transport: any Transport = SilentTransport(), version: String = "", sizeLimit: Int = 64 << 20, releaseBufferSize: Int = 10) -> Environment {
        let store = Store(persistence: Persistence(url: image.url, version: version, sizeLimit: sizeLimit))
        store.reportMissing = nil
        return Environment(transport: transport, store: store, releaseBufferSize: releaseBufferSize)
    }

    /// Waits until the launch has written what it owes the image, and ends
    /// it: one launch has the file open at a time, as on a device.
    func finish(_ environment: Environment) async {
        await environment.store.persistence?.close()
    }

    /// Commits the fixture through its own plan and waits for the image.
    func seed(_ environment: Environment) async throws {
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
        await finish(environment)
    }

    /// The data of a handle the store answers without the network.
    func stored<Op: Baton.Query>(_ operation: Op, in environment: Environment) throws -> Op.Data {
        let handle = environment.handle(for: operation, fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else { throw NotStored() }
        return data
    }

    @Test("a networkOnly attach reads nothing from the image to decide")
    func networkOnlyReadsNoImage() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        await finish(first)

        let gate = GatedTransport()
        let second = launch(gate)
        let handle = second.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        #expect(second.store.hydratedRecords == 0, "the store was not asked")
        guard case .loading = handle.phase else {
            Issue.record("expected loading until its own response, got \(handle.phase)")
            return
        }
        await until { gate.pending == 1 }
        gate.respond(fixtureData)
        await handle.settle()
        await finish(second)
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

    @Test("a lookup the image cannot answer leaves no record behind")
    func aLookupThatMisses() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        await finish(first)

        let second = launch()
        let count = second.store.count
        #expect(throws: NotStored.self) { try stored(TestHeaderQuery(id: "999"), in: second) }
        #expect(second.store.existing("Character:999") == nil)
        #expect(second.store.count == count)
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

    /// Reads an operation from the image, which keeps its rows for the next
    /// launch, and collects it out of memory again: the image alone holds
    /// its records, as after a sweep.
    func readAndSweep<Op: Baton.Query>(_ operation: Op, in environment: Environment) {
        let handle = environment.handle(for: operation, fetchPolicy: .storeOnly)
        guard case .ready = handle.phase else {
            Issue.record("expected the image's data, got \(handle.phase)")
            return
        }
        handle.retain()
        handle.release()
        environment.collect()
    }

    @Test("a record @deleteRecord names that only the image holds does not come back at the next launch")
    func deletionOfARecordInTheImage() async throws {
        try await seed(launch())
        let second = launch(releaseBufferSize: 0)
        readAndSweep(Fixture(page: 1), in: second)
        #expect(second.store.existing("Character:1") == nil, "memory does not hold it")
        let deletion = TestDeleteNote(id: "1")
        second.store.commit(try Ingest.normalize(fixture("delete-record-1"), plan: TestDeleteNote.plan.resolve(deletion.variables), rootKey: Store.mutationRootKey))
        await finish(second)
        // The list held Character:1: without it the list is a miss, and the
        // screen fetches rather than show the deleted character.
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }
    }

    @Test("an edge appended to a connection the store holds only as a link's empty record makes it a miss at every check, in that launch and the next, not a connection of one edge or of none")
    func edgeIntoAConnectionOnlyTheImageHolds() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables)))
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        await finish(first)

        let second = launch(releaseBufferSize: 0)
        readAndSweep(TestNotesQuery(id: "1"), in: second)
        // Reading the character from the image again makes an empty record
        // for the connection its link names.
        let character = try #require(try stored(TestHeaderQuery(id: "1"), in: second).character)
        #expect(character.testHeader.name == "Rick Sanchez")
        let connection = "Character:1:__TestNotes_notes_connection"
        #expect(second.store.existing(connection) != nil)
        let append = TestAddNote(characterId: "1", text: "Appended", connections: [connection])
        second.store.commit(try Ingest.normalize(fixture("add-note-n9"), plan: TestAddNote.plan.resolve(append.variables), rootKey: Store.mutationRootKey))
        let plan = TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables)
        #expect(second.store.check(plan) == .miss, "this launch reads no row of it either")
        // The first check read the page from the image, which leaves the
        // connection's own record, empty, as all memory holds of it.
        #expect(second.store.check(plan) == .miss)
        #expect(throws: NotStored.self) { try stored(TestNotesQuery(id: "1"), in: second) }
        await finish(second)

        // The next launch finds the page's row and none of the connection.
        let third = launch()
        #expect(throws: NotStored.self) { try stored(TestNotesQuery(id: "1"), in: third) }
        #expect(third.store.check(plan) == .miss)
    }

    @Test("an image that lost a batch it could not write is discarded at the next open")
    func lostBatch() async throws {
        try await seed(launch())
        let attributes = [FileAttributeKey.posixPermissions: 0o444]
        let paths = ["", "-wal", "-shm"].map { image.url.path + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        for path in paths { try FileManager.default.setAttributes(attributes, ofItemAtPath: path) }
        let second = launch()
        second.store.commit(try Ingest.normalize(fixture("delete-record-1"), plan: TestDeleteNote.plan.resolve(TestDeleteNote(id: "1").variables), rootKey: Store.mutationRootKey))
        await finish(second)
        // The open after the lost batch discarded the file; what is left is
        // made writable again for the test's own cleanup.
        for path in paths { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }
    }

    @Test("a deferred fragment whose records the image lacks reads absent, not empty, and its operation fetches")
    func deferredDataInTheImage() async throws {
        let first = launch(DeliveryTests.OpenParts([fixture("character-deferred-1"), fixture("character-deferred-2")]))
        let fetched = first.handle(for: TestProfileQuery(id: "1"), fetchPolicy: .networkOnly)
        fetched.retain()
        await until { first.store.existing("Episode:2") != nil && fetched.fetchTime != nil }
        fetched.release()
        await finish(first)
        // The episodes' rows are gone, as after an image that dropped them.
        sql("DELETE FROM records WHERE key LIKE 'Episode:%'")

        let transport = RecordedTransport { _ in fixture("character-deferred-1") }
        let second = launch(transport)
        let handle = second.handle(for: TestProfileQuery(id: "1"), fetchPolicy: .storeOrNetwork)
        guard case .ready(let data) = handle.phase else {
            Issue.record("the initial part renders from the image, got \(handle.phase)")
            return
        }
        #expect(data.character?.testAppearances == nil, "the fragment reads absent, not empty")
        await until { transport.requestCount == 1 }
        await finish(second)
    }

    @Test("records whose rows wait to be written survive a collection, so a check right behind a commit finds them")
    func unwrittenRecordsStay() async throws {
        let environment = launch()
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
        environment.collect()
        #expect(environment.store.check(Fixture.plan.resolve(Fixture(page: 1).variables)) != .miss)
        await finish(environment)
    }

    /// The plan of the header query for a character.
    func header(_ id: String) -> ResolvedSelection {
        TestHeaderQuery.plan.resolve(TestHeaderQuery(id: id).variables)
    }

    /// Commits the root field `whileTheWriterWaits` reads: a character the
    /// server does not know, which the image holds as null.
    func commitUnknown(_ environment: Environment) throws {
        environment.store.commit(try Ingest.normalize(fixture("character-null"), plan: header("999")))
    }

    /// Runs `body` while a check holds the image's connection, which the
    /// writer waits for: what `body` commits is queued and not written until
    /// it returns, the window between a commit and its write held open. The
    /// check reads the field `commitUnknown` wrote in an earlier launch and
    /// this one has not read; memory cannot answer a null, so it comes from
    /// the image, and the field's observer runs `body`.
    func whileTheWriterWaits(in environment: Environment, _ body: @escaping @MainActor () -> Void) {
        let store = environment.store
        let plan = header("999")
        let slot = plan.variant(for: store.root.type).fields[0].slot
        let runs = Notifications()
        withObservationTracking { _ = store.root.read(slot) } onChange: {
            MainActor.assumeIsolated {
                runs.fired += 1
                body()
            }
        }
        _ = store.check(plan)
        #expect(runs.fired == 1 && store.root.read(slot) == .null, "the check read the root field from the image")
    }

    @Test("a root field's new link keeps its record through a collection until the field's row is written, so a check does not read the row before it")
    func aQueuedRootLinkKeepsItsRecord() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("character-null"), plan: header("5")))
        try commitUnknown(first)
        try await seed(first)

        let second = launch(releaseBufferSize: 0)
        let list = second.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        guard case .ready = list.phase else {
            Issue.record("expected the image's data, got \(list.phase)")
            return
        }
        list.retain()
        let detail = header("5")
        let jerry = try Ingest.normalize(fixture("character-header-5"), plan: detail)
        whileTheWriterWaits(in: second) {
            // The list read Jerry as the answer has him: only the root field
            // moves, and the batch holds no snapshot of him.
            #expect(second.store.commit(jerry) == 1)
            list.release()
            second.collect()
            _ = second.store.check(detail)
        }
        let data = try stored(TestHeaderQuery(id: "5"), in: second)
        #expect(data.character?.testHeader.name == "Jerry Smith", "the image's row of the field, not yet written, says null")
        await finish(second)
    }

    @Test("a record @deleteRecord named that only the image holds stays unread while the forget waits for the writer, when a record of another type with its id arrives; that record reads its own row")
    func aForgottenIDIsLiftedOnlyByItsKey() async throws {
        let first = launch()
        try commitUnknown(first)
        try await seed(first)

        let second = launch(releaseBufferSize: 0)
        readAndSweep(Fixture(page: 1), in: second)
        let list = Fixture.plan.resolve(Fixture(page: 1).variables)
        let deletion = try Ingest.normalize(fixture("delete-record-1"), plan: TestDeleteNote.plan.resolve(TestDeleteNote(id: "1").variables), rootKey: Store.mutationRootKey)
        // Albert Einstein, whose origin is `Location:1`.
        let einstein = try Ingest.normalize(fixture("character-header-11"), plan: header("11"))
        let origin = TestConditions.plan.resolve(TestConditions(id: "11", withOrigin: true, hideStatus: false).variables)
        whileTheWriterWaits(in: second) {
            second.store.commit(deletion)
            #expect(second.store.check(list) == .miss, "the list holds Character:1")
            second.store.commit(einstein)
            #expect(second.store.check(list) == .miss, "a payload with Location:1 brings Character:1 back")
            #expect(second.store.check(origin) == .image, "Location:1's dimension, which the payload lacks, comes from its row")
        }
        await second.store.persistence?.flush()
        #expect(second.store.check(list) == .miss, "the writer has dropped the row")
        await finish(second)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }
    }

    @Test("data read every launch keeps its age: expired in the second launch, still dated and fresh in the third")
    func ageReadEveryLaunch() async throws {
        let transport = RecordedTransport { _ in fixtureData }
        let first = launch(transport)
        let fetched = first.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        fetched.retain()
        await fetched.settle()
        await finish(first)

        let second = launch(transport)
        second.queryCacheExpiration = .zero
        let expired = second.handle(for: TestList(page: 1), fetchPolicy: .storeOnly)
        #expect(expired.fetchTime != nil)
        #expect(expired.isStale, "the age came from the image, and it is past the expiration")
        await finish(second)

        let third = launch(transport)
        let dated = third.handle(for: TestList(page: 1), fetchPolicy: .storeOnly)
        guard case .ready = dated.phase else {
            Issue.record("expected the image's data, got \(dated.phase)")
            return
        }
        #expect(dated.fetchTime != nil, "the second launch's read kept the fetch time")
        #expect(!dated.isStale)
        #expect(transport.requestCount == 1)
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

    @Test("a root field an earlier check read from the image is image data for the next operation that reads it, stale without a fetch time of its own")
    func aRootFieldFromTheImageIsImageData() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("character-null"), plan: header("999")))
        await finish(first)

        let transport = RecordedTransport { _ in fixture("character-null") }
        let second = launch(transport)
        _ = try stored(TestHeaderQuery(id: "999"), in: second)
        // Another operation on the same root field, which no launch fetched.
        let qualified = TestQualifiedQuery(id: "999")
        #expect(second.store.check(TestQualifiedQuery.plan.resolve(qualified.variables)) == .image)
        let handle = second.handle(for: qualified, fetchPolicy: .storeOrNetwork)
        #expect(handle.isStale)
        await until { transport.requestCount == 1 }
        await finish(second)
    }

    @Test("records the collector swept are read again from the image when a screen comes back")
    func sweptRecordsComeBack() async throws {
        let environment = launch(releaseBufferSize: 0)
        try await seed(environment)
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

    @Test("an unreadable image is a miss: garbage, another version and a removed image start over")
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

        // A sign-out deletes the image, and the work queued before it with
        // it; memory keeps what it had.
        let leaving = launch(version: "2")
        _ = try stored(Fixture(page: 1), in: leaving)
        leaving.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
        leaving.store.persistence?.removeAll()
        #expect(!FileManager.default.fileExists(atPath: image.url.path), "the file is gone, names and all")
        await finish(leaving)
        _ = try stored(Fixture(page: 1), in: leaving)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch(version: "2")) }
    }

    /// Runs SQL against the image through a connection of the test's own;
    /// `bind` binds the statement's parameters.
    func sql(_ text: String, _ bind: (OpaquePointer) -> Void = { _ in }) {
        var db: OpaquePointer?
        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        bind(statement!)
        let status = sqlite3_step(statement)
        #expect(status == SQLITE_DONE || status == SQLITE_ROW, "\(text): \(status)")
    }

    /// The id the image interned a name under.
    func nameID(_ name: String) -> UInt8 {
        var db: OpaquePointer?
        sqlite3_open(image.url.path, &db)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM names WHERE name = ?1", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        #expect(sqlite3_step(statement) == SQLITE_ROW, "the image names \(name)")
        let id = sqlite3_column_int64(statement, 0)
        #expect(id < 0x80, "a one-byte varint")
        return UInt8(id)
    }

    @Test("an image of another format is a miss, and the next commit starts it again")
    func anotherFormat() async throws {
        try await seed(launch())
        sql("PRAGMA user_version = 99")
        let next = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: next) }
        try await seed(next)
        _ = try stored(Fixture(page: 1), in: launch())
    }

    @Test("an image past its size limit is a miss and starts again")
    func overTheSizeLimit() async throws {
        try await seed(launch())
        let size = try #require(try FileManager.default.attributesOfItem(atPath: image.url.path)[.size] as? Int)
        #expect(size > 4096)
        let small = launch(sizeLimit: 4096)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: small) }
        await finish(small)
        let after = try #require(try FileManager.default.attributesOfItem(atPath: image.url.path)[.size] as? Int)
        #expect(after < size, "the file was deleted and made again")
    }

    @Test("a damaged row is read as far as it goes: a name past any table, a link to no type, lists nested in lists, a row cut short")
    func damagedRows() async throws {
        try await seed(launch())
        let character = nameID("Character")
        // The row format's tags: null 0, string 5, link 6, list 8.
        let (null, string, link, list): (UInt8, UInt8, UInt8, UInt8) = (0, 5, 6, 8)
        let rows: [String: [UInt8]] = [
            // A name id with bit 63 set.
            "Character:1": [0x02, character] + [UInt8](repeating: 0xFF, count: 9) + [0x01, null],
            // A link whose head names no type.
            "Character:2": [0x02, character, nameID("origin"), link, 0x01],
            // A list of lists, deeper than any stack.
            "Character:3": [0x02, character, nameID("name")] + Array(repeating: [list, 0x01], count: 200_000).flatMap { $0 } + [null],
            // A string longer than the row.
            "Character:4": [0x02, character, nameID("name"), string, 0x7F, 0x41],
        ]
        for (key, row) in rows {
            sql("UPDATE records SET row = ?2 WHERE key = ?1") { statement in
                sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                _ = row.withUnsafeBufferPointer { bytes in
                    sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
        }
        let next = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: next) }
        let morty = try #require(next.store.existing("Character:2"))
        #expect(!morty.deleted)
    }

    @Test("a Float the image holds where the document reads an Int reads as nil, not a trap or a truncation")
    func aFloatWhereAnIntIsRead() async throws {
        try await seed(launch())
        let info = "client:root:characters(page:1):info"
        // A row of the info record: its type, then `count` holding a double
        // past any Int and `pages` holding 2.5.
        func double(_ value: Double) -> [UInt8] { [4] + withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) } }
        let row: [UInt8] = [0, nameID("Info"), nameID("count")] + double(1e300) + [nameID("pages")] + double(2.5)
        sql("UPDATE records SET row = ?2 WHERE key = ?1") { statement in
            sqlite3_bind_text(statement, 1, info, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = row.withUnsafeBufferPointer { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        let next = launch()
        let store = next.store
        let data = Fixture.Data(anchor: Anchor(record: store.root, variables: Fixture(page: 1).variables, store: store))
        _ = store.check(Fixture.plan.resolve(Fixture(page: 1).variables))
        #expect(data.characters?.info?.count == nil)
        #expect(data.characters?.info?.pages == nil)
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

    @Test("a file damaged between a commit and a check is a miss, not a crash")
    func damagedUnderAnOpenConnection() async throws {
        // Whether the check or the writer meets the damage first is a race;
        // a few rounds give the check its turn.
        for _ in 0..<12 {
            let image = TemporaryImage()
            let first = Store(persistence: Persistence(url: image.url))
            first.reportMissing = nil
            first.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
            await first.persistence?.flush()
            // The image's connection stays open while another moves its rows
            // into the main file and every page after the first is
            // overwritten, so a transaction begins and its first write finds
            // the damage.
            var other: OpaquePointer?
            #expect(sqlite3_open(image.url.path, &other) == SQLITE_OK)
            #expect(sqlite3_exec(other, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(other)
            let handle = try FileHandle(forWritingTo: image.url)
            try handle.seek(toOffset: 4096)
            try handle.write(contentsOf: Data(repeating: 0x42, count: 1 << 18))
            try handle.close()
            let renamed = String(decoding: fixtureData, as: UTF8.self)
                .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
            first.commit(try Ingest.normalize(Data(renamed.utf8), plan: Fixture.plan.resolve(Fixture(page: 1).variables)))
            let second = Store(persistence: first.persistence)
            second.reportMissing = nil
            #expect(second.check(Fixture.plan.resolve(Fixture(page: 1).variables)) == .miss)
            await first.persistence?.flush()
        }
    }
}
