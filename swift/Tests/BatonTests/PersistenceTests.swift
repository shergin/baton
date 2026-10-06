@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import SQLite3
import Testing

/// A file for one test's image, removed with its journal when the test ends.
final class TemporaryImage {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm", "-discard"] {
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
    /// each with `finish`. `url` spells the image's path another way;
    /// `cacheExpiration` is the store's default.
    func launch(_ transport: any Transport = SilentTransport(), at url: URL? = nil, version: String = "", sizeLimit: Int = 64 << 20, protection: FileProtectionType? = nil, cacheExpiration: Duration? = nil, releaseBufferSize: Int = 10) -> Environment {
        let store = Store(persistence: Persistence(url: url ?? image.url, version: version, sizeLimit: sizeLimit, protection: protection), cacheExpiration: cacheExpiration, releaseBufferSize: releaseBufferSize)
        store.reportMissing = nil
        return Environment(transport: transport, store: store)
    }

    /// Waits until the launch has written what it owes the image, and ends
    /// it: one launch has the file open at a time, as on a device.
    func finish(_ environment: Environment) async {
        await environment.store.persistence?.close()
    }

    /// Commits the fixture through its own plan and waits for the image.
    func seed(_ environment: Environment) async throws {
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)))
        await finish(environment)
    }

    /// The data of a handle the store answers without the network.
    func stored<Op: Baton.Query>(_ operation: Op, in environment: Environment) throws -> Op.Data {
        let handle = environment.handle(for: operation, fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else { throw NotStored() }
        return data
    }

    /// The `totalCount` of the connection a record links to under a slot,
    /// or nil when the slot holds no link.
    func totalCount(_ record: Record, _ slot: Slot) -> Int? {
        guard case .ref(let connection) = record.read(slot) else { return nil }
        guard case .int(let count) = connection.read(Registry.slot(connection.type, "totalCount")) else { return nil }
        return count
    }

    @Test("the memberships a response taught are kept by the image for the next launch")
    func membershipsAreKeptByTheImage() async throws {
        let search = TestUnion(name: "robot")
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("union-unknown-type"), plan: TestUnion.plan.resolve(search.variables, in: first.store.keys)))
        await finish(first)
        // The SQL proves the write. The learned table is the process's, so
        // the read below proves the image answers the case, not that the
        // second launch learned the memberships from the file.
        #expect(integer("SELECT count(*) FROM memberships WHERE type = 'Robot' AND condition = 'Named'") == 1)
        #expect(integer("SELECT count(*) FROM memberships WHERE type = 'Robot' AND condition = 'Node'") == 1)
        #expect(integer("SELECT count(*) FROM memberships WHERE type = 'Character'") == 0, "a listed type needs no answer")

        let second = launch()
        let data = try stored(search, in: second)
        let results = try #require(data.search)
        #expect(results.count == 2)
        #expect(results[0].asNamed?.name == "Butter Robot")
        #expect(results[0].asCharacter == nil)
        #expect(results[1].asNamed?.name == "Rick Sanchez")
        await finish(second)
    }

    @Test("a row the image named by a rendered key is read through a constant of its text the build named before the next launch")
    func aRenderedRowIsReadThroughALaterConstant() async throws {
        // A count no other test renders or names.
        let written = TestNoteCounts(page: 1, count: 94)
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: first.store.keys)))
        await finish(first)

        let constant = Registry.slot(Registry.type("Character"), "notes(first:94)")
        let second = launch()
        let data = try stored(written, in: second)
        #expect(data.characters?.results?.map(\.recent.totalCount) == [3, 0])
        #expect(totalCount(try #require(second.store.existing("Character:1")), constant) == 3, "the constant reads the row the rendering wrote")
        #expect(second.store.keys.count(on: Registry.type("Character")) == 0, "the second launch numbered nothing for the text")
        await finish(second)
    }

    @Test("a row hydrated under a rendered key is adopted by a constant of its text the build names afterwards")
    func aHydratedRenderingIsAdoptedByALaterConstant() async throws {
        // A count no other test renders or names.
        let written = TestNoteCounts(page: 1, count: 93)
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: first.store.keys)))
        await finish(first)

        let second = launch()
        let data = try stored(written, in: second)
        #expect(data.characters?.results?.first?.recent.totalCount == 3)
        let record = try #require(second.store.existing("Character:1"))
        let rendered = try #require(record.storedSlots.map(\.slot).first { second.store.storageKey(of: $0) == "notes(first:93)" })
        #expect(rendered.index < 0, "the image's row filled the store's number")

        let constant = Registry.slot(Registry.type("Character"), "notes(first:93)")
        // A lens over the store that renders another key meets the constant.
        _ = TestHeaderQuery.Data(anchor: Anchor(record: second.store.root, variables: TestHeaderQuery(id: "1").variables, store: second.store)).character
        #expect(totalCount(record, constant) == 3, "the constant reads the hydrated row")
        await finish(second)
    }

    @Test("a networkOnly attach reads nothing from the image to decide")
    func networkOnlyReadsNoImage() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: first.store.keys)))
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

    @Test("a payload committed by hand reaches the image, and the next launch answers its operation from it")
    func aPayloadCommittedByHandReachesTheImage() async throws {
        let first = launch()
        try await first.commitPayload(Fixture(page: 1), fixtureData)
        await finish(first)

        let second = launch()
        let data = try stored(Fixture(page: 1), in: second)
        #expect(second.store.hydratedRecords == 898)
        #expect(data.characters?.results?.first?.name == "Rick Sanchez")
        #expect(data.characters?.info?.count == 826)
        await finish(second)
    }

    @Test("a refetch after a launch changes one row, and the next launch reads the change")
    func aRefetchReachesTheImage() async throws {
        try await seed(launch())

        let renamed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let second = launch(RecordedTransport { _ in Data(renamed.utf8) })
        let handle = second.handle(for: Fixture(page: 1))
        let retention = handle.retain()
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
        withExtendedLifetime(retention) {}
    }

    @Test("a mutation's answer is in the image and an optimistic response never is")
    func optimisticResponsesStayInMemory() async throws {
        let first = launch()
        try await seed(first)
        let rename = TestRename(id: "1", name: "Rick Prime")
        let optimistic = TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable
        let json = Data(("{\"data\":" + optimistic.json + "}").utf8)
        _ = first.store.applyOptimistic(try Ingest.normalize(json, plan: TestRename.plan.resolve(rename.variables, in: first.store.keys), rootKey: Store.mutationRootKey))
        // A commit under the layer writes the server's values, not the layer's.
        let refreshed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"status\":\"Alive\"", with: "\"status\":\"Busy\"")
        first.store.commit(try Ingest.normalize(Data(refreshed.utf8), plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: first.store.keys)))
        #expect(first.store.existing("Character:1")?.read(Registry.slot(Registry.type("Character"), "name")) == .string("Rick Prime"))
        await finish(first)

        let second = launch()
        let before = try stored(Fixture(page: 1), in: second)
        #expect(before.characters?.results?[0].name == "Rick Sanchez", "the layer was never written")
        #expect(before.characters?.results?[0].status == "Busy", "the commit under it was")
        let answer = fixture("rename-1")
        second.store.commit(try Ingest.normalize(answer, plan: TestRename.plan.resolve(rename.variables, in: second.store.keys), rootKey: Store.mutationRootKey))
        await finish(second)

        let third = try stored(Fixture(page: 1), in: launch())
        #expect(third.characters?.results?[0].name == "Rick Prime")
    }

    @Test("field errors survive a launch: @catch reads the error the first launch received")
    func fieldErrorsSurvive() async throws {
        let first = launch(RecordedTransport([TestProfileQuery.name: fixture("character-errors")]))
        let fetched = first.handle(for: TestProfileQuery(id: "1"))
        let fetchedRetention = fetched.retain()
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
        withExtendedLifetime(fetchedRetention) {}
    }

    @Test("a field error's extensions survive a launch: @catch reads the value the first launch received, and an error without them reads nil")
    func fieldErrorExtensionsSurvive() async throws {
        let first = launch(RecordedTransport([TestProfileQuery.name: Data(DeliveryTests.extensionsResponse.utf8)]))
        let fetched = first.handle(for: TestProfileQuery(id: "1"))
        let fetchedRetention = fetched.retain()
        await fetched.settle()
        await finish(first)

        let data = try stored(TestProfileQuery(id: "1"), in: launch())
        let character = try #require(data.character?.testProfile)
        guard case .failure(let image) = character.image else {
            Issue.record("the image lost the error")
            return
        }
        #expect(image.errors == [FieldError(message: "image service unavailable", path: "character.image", extensions: DeliveryTests.extensions)])
        guard case .failure(let location) = character.location else {
            Issue.record("the image lost the error inside location")
            return
        }
        #expect(location.errors.map(\.extensions) == [nil])
        withExtendedLifetime(fetchedRetention) {}
    }

    @Test("a refetch of a fragment read from the image carries the id read from the slot its query names, the owner's id field")
    func aRefetchFromTheImageCarriesTheIDField() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: first.store.keys)))
        await finish(first)

        let transport = RecordedTransport { _ in fixture("notes-refetch") }
        let second = launch(transport)
        let data = try stored(TestNotesQuery(id: "1"), in: second)
        let character = try #require(data.character?.testNotes)
        let record = try #require(second.store.existing("Character:1"))
        let id = record.read(Registry.slot(record.type, "id"))
        #expect(id == .string("1"), "the image filled the owner's id field")

        try await character.refetch()
        let request = try #require(transport.requests.last)
        #expect(request.operationName == "TestNotesPaginationQuery")
        #expect(request.variables["id"] == .string("1"), "the refetch carries the id field's value")
        #expect(character.notes.nodes.first?.text == "Wubba lubba dub dub!")
    }

    @Test("a connection's merged pages and a deletion survive a launch, and the loading flag does not")
    func connectionsSurvive() async throws {
        let first = launch(notesTransport())
        let fetched = first.handle(for: TestNotesQuery(id: "1"))
        let fetchedRetention = fetched.retain()
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
        first.store.commit(try Ingest.normalize(payload, plan: TestRemoveNote.plan.resolve(removal.variables, in: first.store.keys), rootKey: Store.mutationRootKey))
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
        withExtendedLifetime(fetchedRetention) {}
    }

    @Test("an entity the image holds satisfies a lookup: a detail renders from a list an earlier launch fetched")
    func lookupsReadTheImage() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: first.store.keys)))
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
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: first.store.keys)))
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
        let fetchedRetention = fetched.retain()
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

        let third = launch(transport, cacheExpiration: .zero)
        let expired = third.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let expiredRetention = expired.retain()
        #expect(expired.isStale)
        await expired.settle()
        #expect(transport.requestCount == 2, "expired data is")
        _ = consume expiredRetention
        await finish(third)

        // The refetch wrote its own age: a launch without the expiration
        // reads it fresh.
        let fourth = launch(transport)
        let refetched = fourth.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let refetchedRetention = refetched.retain()
        #expect(!refetched.isStale)
        await refetched.settle()
        #expect(transport.requestCount == 2)
        fourth.invalidate()
        await refetched.settle()
        #expect(transport.requestCount == 3, "a retained handle refetches when everything is invalidated")
        // An invalidation that nothing refetched reaches the next launch.
        _ = consume refetchedRetention
        fourth.invalidate()
        await finish(fourth)

        let fifth = launch(transport)
        let invalidated = fifth.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(invalidated.isStale, "the invalidation outlived the launch")
        await invalidated.settle()
        #expect(transport.requestCount == 4)
        withExtendedLifetime(fetchedRetention) {}
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
        let retention = handle.retain()
        _ = consume retention
        environment.store.collect()
    }

    @Test("a record @deleteRecord names that only the image holds does not come back at the next launch")
    func deletionOfARecordInTheImage() async throws {
        try await seed(launch())
        let second = launch(releaseBufferSize: 0)
        readAndSweep(Fixture(page: 1), in: second)
        #expect(second.store.existing("Character:1") == nil, "memory does not hold it")
        let deletion = TestDeleteNote(id: "1")
        second.store.commit(try Ingest.normalize(fixture("delete-record-1"), plan: TestDeleteNote.plan.resolve(deletion.variables, in: second.store.keys), rootKey: Store.mutationRootKey))
        await finish(second)
        // The list held Character:1: without it the list is a miss, and the
        // screen fetches rather than show the deleted character.
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }
    }

    @Test("an edge appended to a connection the store holds only as a link's empty record makes it a miss at every check, in that launch and the next, not a connection of one edge or of none")
    func edgeIntoAConnectionOnlyTheImageHolds() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: first.store.keys)))
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: first.store.keys)))
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
        second.store.commit(try Ingest.normalize(fixture("add-note-n9"), plan: TestAddNote.plan.resolve(append.variables, in: second.store.keys), rootKey: Store.mutationRootKey))
        let plan = TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: second.store.keys)
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

    /// The image's file and the journal files beside it that exist now.
    var imageFiles: [String] {
        ["", "-wal", "-shm"].map { image.url.path + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Sets the permissions of each of `paths`.
    func permit(_ permissions: Int, _ paths: [String]) throws {
        for path in paths { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
    }

    /// The marker beside the image that has the next open discard it.
    var marker: String { image.url.path + "-discard" }

    @Test("work the image's file cannot take waits for it, and lands when the file can be taken again")
    func workWaitsForTheFile() async throws {
        try await seed(launch())
        let paths = imageFiles
        let size = try #require(try FileManager.default.attributesOfItem(atPath: image.url.path)[.size] as? Int)
        try permit(0o444, paths)
        defer { try? permit(0o644, paths) }

        let second = launch()
        second.store.commit(try Ingest.normalize(fixture("delete-record-1"), plan: TestDeleteNote.plan.resolve(TestDeleteNote(id: "1").variables, in: second.store.keys), rootKey: Store.mutationRootKey))
        await second.store.persistence?.flush()
        // The file could not take the deletion, and is neither changed nor
        // marked for it.
        #expect(FileManager.default.fileExists(atPath: image.url.path), "the image was not discarded")
        #expect(try FileManager.default.attributesOfItem(atPath: image.url.path)[.size] as? Int == size)
        #expect(!FileManager.default.fileExists(atPath: marker))

        try permit(0o644, paths)
        try await Task.sleep(for: .seconds(1.1))
        await second.store.persistence?.flush()
        await finish(second)

        // The deletion landed in the image, which kept the rest.
        let third = launch()
        #expect(throws: NotStored.self) { try stored(TestHeaderQuery(id: "1"), in: third) }
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: third) }
        let morty = try stored(TestHeaderQuery(id: "2"), in: third)
        #expect(morty.character?.testHeader.name == "Morty Smith")
        await finish(third)
    }

    @Test("work that waits for the image's file past the wait limit is dropped, and the image starts again at the next open")
    func workPastTheWaitLimitIsDropped() async throws {
        try await seed(launch())
        let paths = imageFiles
        try permit(0o444, paths)
        defer { try? permit(0o644, paths) }

        // Every commit renames every named record, so each one queues a
        // snapshot of nearly the whole fixture; the commits go on until the
        // queue outgrows the limit and the image is marked.
        let text = String(decoding: fixtureData, as: UTF8.self)
        let second = launch()
        let plan = Fixture.plan.resolve(Fixture(page: 1).variables, in: second.store.keys)
        var commits = 0
        while !FileManager.default.fileExists(atPath: marker), commits < 500 {
            let renamed = text.replacingOccurrences(of: "\"name\":\"", with: "\"name\":\"\(commits) ")
            second.store.commit(try Ingest.normalize(Data(renamed.utf8), plan: plan))
            await second.store.persistence?.flush()
            commits += 1
        }
        #expect(FileManager.default.fileExists(atPath: marker), "the image was marked once the work outgrew the limit")
        #expect(commits > 1, "one commit's work waits")
        #expect(FileManager.default.fileExists(atPath: image.url.path), "the file itself is left for the next open")

        try permit(0o644, paths)
        await finish(second)
        let third = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: third) }
        #expect(third.store.hydratedRecords == 0)
        #expect(!FileManager.default.fileExists(atPath: marker))
        await finish(third)
    }

    @Test("a deferred fragment whose records the image lacks reads absent, not empty, and its operation fetches")
    func deferredDataInTheImage() async throws {
        let first = launch(DeliveryTests.OpenParts([fixture("character-deferred-1"), fixture("character-deferred-2")]))
        let fetched = first.handle(for: TestProfileQuery(id: "1"), fetchPolicy: .networkOnly)
        let fetchedRetention = fetched.retain()
        await until { first.store.existing("Episode:2") != nil && fetched.fetchTime != nil }
        _ = consume fetchedRetention
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
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)))
        environment.store.collect()
        #expect(environment.store.check(Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)) != .miss)
        await finish(environment)
    }

    /// The plan of the header query for a character.
    func header(_ id: String, in store: Store) -> ResolvedSelection {
        TestHeaderQuery.plan.resolve(TestHeaderQuery(id: id).variables, in: store.keys)
    }

    /// Commits a root field the server does not know a character for, which
    /// the image holds as null.
    func commitUnknown(_ environment: Environment) throws {
        environment.store.commit(try Ingest.normalize(fixture("character-null"), plan: header("999", in: environment.store)))
    }

    /// Runs `body` while the image's writer is held: what `body` commits is
    /// queued and not written until it returns, the window between a commit
    /// and its write held open. The file is not held, so the checks `body`
    /// runs read the image.
    func whileTheWriterWaits(in environment: Environment, _ body: () -> Void) {
        guard let persistence = environment.store.persistence else {
            Issue.record("the environment has no image")
            return
        }
        persistence.holdingTheWriter { body() }
    }

    @Test("a root field's new link keeps its record through a collection until the field's row is written, so a check does not read the row before it")
    func aQueuedRootLinkKeepsItsRecord() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("character-null"), plan: header("5", in: first.store)))
        try await seed(first)

        let second = launch(releaseBufferSize: 0)
        let list = second.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        guard case .ready = list.phase else {
            Issue.record("expected the image's data, got \(list.phase)")
            return
        }
        var listRetention: Retention? = list.retain()
        let detail = header("5", in: second.store)
        let jerry = try Ingest.normalize(fixture("character-header-5"), plan: detail)
        whileTheWriterWaits(in: second) {
            // The list read Jerry as the answer has him: only the root field
            // moves, and the batch holds no snapshot of him.
            #expect(second.store.commit(jerry) == 1)
            _ = listRetention.take()
            second.store.collect()
            _ = second.store.check(detail)
        }
        let data = try stored(TestHeaderQuery(id: "5"), in: second)
        #expect(data.character?.testHeader.name == "Jerry Smith", "the image's row of the field, not yet written, says null")
        await finish(second)
    }

    @Test("a key in a row the image has not written yet is kept through a collection, and freed after the write")
    func anUnwrittenRowKeepsItsKey() async throws {
        let environment = launch()
        let store = environment.store
        let query = Registry.type("Query")
        // The resolution goes with the statement: once the commit is queued,
        // only its waiting row names the key.
        let jerry = try Ingest.normalize(fixture("character-header-5"), plan: header("5", in: store))
        whileTheWriterWaits(in: environment) {
            store.commit(jerry)
            store.collect()
            #expect(store.keys.count(on: query) == 1, "the row waiting for the writer keeps its key")
        }
        await store.persistence?.flush()
        store.collect()
        #expect(store.keys.count(on: query) == 0, "the written row names the key no more")
        await finish(environment)

        let second = launch()
        #expect(try stored(TestHeaderQuery(id: "5"), in: second).character?.testHeader.name == "Jerry Smith", "the row was written under the key's text")
        await finish(second)
    }

    @Test("a row written under a freed number is named by the new key, not the old")
    func aRowUnderAFreedNumberIsNamedByItsNewKey() async throws {
        let transport = RecordedTransport { request in
            guard case .string(let id)? = request.variables["id"] else { return nil }
            return fixture("character-header-\(id)")
        }
        let first = launch(transport, releaseBufferSize: 0)
        let store = first.store
        func slot(_ id: String) -> Slot {
            Owner(variables: TestHeaderQuery(id: id).variables, store: store).slot(Slots.Query.character_bca4f9)
        }
        let freed: Slot
        do {
            let handle = first.handle(for: TestHeaderQuery(id: "5"))
            let retention = handle.retain()
            await handle.settle()
            freed = slot("5")
            _ = consume retention
        }
        // The row is written first, so that no waiting row keeps the key.
        await store.persistence?.flush()
        store.collect()
        #expect(store.storageKey(of: freed) == "", "the released lookup's key is freed")
        let reused: Slot
        do {
            let handle = first.handle(for: TestHeaderQuery(id: "11"))
            let retention = handle.retain()
            await handle.settle()
            guard case .ready = handle.phase else { Issue.record("expected ready, got \(handle.phase)"); return }
            reused = slot("11")
            withExtendedLifetime(retention) {}
        }
        #expect(reused == freed, "the next lookup takes the freed number")
        await finish(first)

        let second = launch()
        #expect(try stored(TestHeaderQuery(id: "11"), in: second).character?.testHeader.name == "Albert Einstein", "the row written under the number is named by the new key")
        #expect(try stored(TestHeaderQuery(id: "5"), in: second).character?.testHeader.name == "Jerry Smith", "the old key's row stays under its own text, which the image did not lend the new row")
        await finish(second)
    }

    @Test("a key a record's row was read under stays numbered while the image lives, and a root field's key is freed and read from the image again")
    func aHydratedKeyStaysNumbered() async throws {
        // A count no other test renders or names.
        let written = TestNoteCounts(page: 1, count: 91)
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: first.store.keys)))
        await finish(first)

        let second = launch(releaseBufferSize: 0)
        let store = second.store
        // Reads the operation from the image through a handle that is gone,
        // its root with it, when this returns.
        func read() -> [Int]? {
            let handle = second.handle(for: written, fetchPolicy: .storeOnly)
            let retention = handle.retain()
            defer { withExtendedLifetime(retention) {} }
            guard case .ready(let data) = handle.phase else { return nil }
            return data.characters?.results?.map(\.recent.totalCount)
        }
        #expect(read() == [3, 0])
        store.collect()
        #expect(store.existing("Character:1") == nil, "the released operation's records were swept")
        #expect(store.keys.count(on: Registry.type("Character")) == 1, "the image holds the key a record's row filled a value under")
        #expect(store.keys.count(on: Registry.type("Query")) == 0, "a root field's key is freed: the image finds its row by its text")
        #expect(read() == [3, 0], "the root field is read from the image again under its next number")
        await finish(second)
    }

    /// The first column of the first row a query of the image returns, as
    /// an integer; nil for no row or a null.
    func integer(_ text: String, _ name: String? = nil) -> Int64? {
        var db: OpaquePointer?
        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK, "\(text)")
        defer { sqlite3_finalize(statement) }
        if let name { sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// Whether the image's table of names holds a name.
    func names(_ name: String) -> Bool {
        integer("SELECT count(*) FROM names WHERE name = ?1", name) == 1
    }

    /// Commits the counts of the first page's characters' notes, rendering
    /// `notes(first:<count>)` on each character's row.
    func commitNoteCounts(_ count: Int, in environment: Environment) throws {
        let operation = TestNoteCounts(page: 1, count: count)
        environment.store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(operation.variables, in: environment.store.keys)))
    }

    @Test("names no row uses any more are swept at a launch's first batch, and their ids are used again")
    func unusedNamesAreSwept() async throws {
        // Counts no other test renders or names.
        let first = launch()
        try commitNoteCounts(90, in: first)
        await finish(first)
        #expect(names("notes(first:90)"), "the rows name the rendered key")
        let highest = try #require(integer("SELECT max(id) FROM names"))

        // Two launches that read nothing, so the first launch's rows age out
        // at the next launch's first batch.
        await finish(launch())
        await finish(launch())
        let fourth = launch()
        try commitNoteCounts(88, in: fourth)
        await fourth.store.persistence?.flush()
        #expect(!names("notes(first:90)"), "the name went with the rows that used it")
        let reused = try #require(integer("SELECT id FROM names WHERE name = ?1", "notes(first:88)"))
        #expect(reused < highest, "the new name took an id the sweep freed")
        #expect(integer("SELECT count(*) FROM names") == integer("SELECT max(id) + 1 FROM names"), "the table holds no hole: every name was swept and interned again from the lowest id")
        await finish(fourth)

        let fifth = launch()
        let data = try stored(TestNoteCounts(page: 1, count: 88), in: fifth)
        #expect(data.characters?.results?.map(\.recent.totalCount) == [3, 0], "the rows written after the sweep read back")
        await finish(fifth)
    }

    @Test("a name a remaining row uses survives the sweep, and the row's names read back")
    func aUsedNameSurvivesTheSweep() async throws {
        let first = launch()
        try commitNoteCounts(89, in: first)
        first.store.commit(try Ingest.normalize(fixture("character-header-5"), plan: header("5", in: first.store)))
        await finish(first)
        // The list's rows alone carry the rendered key; Jerry's alone carry
        // `species`.
        #expect(names("notes(first:89)"))
        #expect(names("species"))

        // Two launches read Jerry and nothing else; at the second one's first
        // batch the list's rows age out and the names are swept.
        for _ in 0..<2 {
            let launched = launch()
            let data = try stored(TestHeaderQuery(id: "5"), in: launched)
            #expect(data.character?.testHeader.name == "Jerry Smith")
            await finish(launched)
        }
        #expect(!names("notes(first:89)"), "the sweep ran: the aged rows' name is gone")
        #expect(names("species"), "the name the remaining row uses stays")

        let last = launch()
        #expect(throws: NotStored.self) { try stored(TestNoteCounts(page: 1, count: 89), in: last) }
        let data = try stored(TestHeaderQuery(id: "5"), in: last)
        let jerry = data.character?.testHeader
        #expect(jerry?.name == "Jerry Smith", "the remaining row reads back through its names")
        #expect(jerry?.species == "Human")
        #expect(jerry?.status == "Alive")
        #expect(jerry?.origin?.name == "Earth (Replacement Dimension)")
        await finish(last)
    }

    /// A plan that writes one field rendered from `cursor` on a character
    /// the root field `sweepProbe` links to, so that its commit interns the
    /// rendered key alone among names Jerry's row also uses.
    func probePlan(_ cursor: String, in store: Store) -> ResolvedSelection {
        let query = Registry.type("Query")
        let character = Registry.type("Character")
        let items = DynamicKey(character, "items", [KeyArgument("after", [.variable("cursor")])])
        return Plan(root: Selection(type: query, key: nil, fields: [
            .linked("sweepProbe", key: .fixed(Registry.slot(query, "sweepProbe")), plural: false, selection: Selection(type: character, key: "id", fields: [
                .scalar("id", key: .fixed(Registry.slot(character, "id")), kind: .string, list: false),
                .scalar("items", key: .dynamic(items), kind: .string, list: false),
            ])),
        ])).resolve(Variables(["cursor": .string(cursor)]), in: store.keys)
    }

    /// Commits a probe character with a field under `items(after:<cursor>)`.
    func commitProbe(_ id: String, _ cursor: String, in environment: Environment) throws {
        let response = #"{"data":{"sweepProbe":{"id":"\#(id)","items":"page \#(cursor)"}}}"#
        environment.store.commit(try Ingest.normalize(Data(response.utf8), plan: probePlan(cursor, in: environment.store)))
    }

    @Test("a table of names with a hole below a live name loads, and the hole's id is the first used again")
    func aHoleBelowALiveNameIsUsedAgain() async throws {
        // The probe's key is interned before Jerry's names, below them.
        let first = launch()
        try commitProbe("870", "c87", in: first)
        first.store.commit(try Ingest.normalize(fixture("character-header-5"), plan: header("5", in: first.store)))
        await finish(first)
        let swept = try #require(integer("SELECT id FROM names WHERE name = ?1", #"items(after:"c87")"#))
        let species = try #require(integer("SELECT id FROM names WHERE name = ?1", "species"))
        #expect(swept < species)

        // Two launches read Jerry alone: the probe's rows age out and the
        // sweep leaves a hole at its key's id, below `species`.
        for _ in 0..<2 {
            let launched = launch()
            #expect(try stored(TestHeaderQuery(id: "5"), in: launched).character?.testHeader.name == "Jerry Smith")
            await finish(launched)
        }
        #expect(!names(#"items(after:"c87")"#), "the aged rows' key is swept")
        #expect(integer("SELECT id FROM names WHERE name = ?1", "species") == species, "a live name keeps its id")
        #expect(integer("SELECT max(id) + 1 - count(*) FROM names") == 1, "the table has one hole")

        // This launch reads Jerry too, or his rows would age out by the next.
        let reusing = launch()
        #expect(try stored(TestHeaderQuery(id: "5"), in: reusing).character?.testHeader.name == "Jerry Smith")
        try commitProbe("860", "c86", in: reusing)
        await reusing.store.persistence?.flush()
        #expect(integer("SELECT id FROM names WHERE name = ?1", #"items(after:"c86")"#) == swept, "the new name took the hole's id")
        #expect(integer("SELECT max(id) + 1 - count(*) FROM names") == 0, "and filled the hole")
        await finish(reusing)

        let last = launch()
        let store = last.store
        let jerry = try stored(TestHeaderQuery(id: "5"), in: last).character?.testHeader
        #expect(jerry?.name == "Jerry Smith", "the table with a hole loaded, and Jerry's names read back")
        #expect(jerry?.species == "Human")
        let plan = probePlan("c86", in: store)
        #expect(store.check(plan) != .miss, "the probe's row reads from the image")
        let probe = try #require(store.existing("Character:860"))
        let slot = Owner(variables: Variables(["cursor": .string("c86")]), store: store).slot(DynamicKey(Registry.type("Character"), "items", [KeyArgument("after", [.variable("cursor")])]))
        #expect(probe.read(slot) == .string("page c86"), "the reused id names the new text")
        withExtendedLifetime(plan) {}
        await finish(last)
    }

    @Test("a record @deleteRecord named that only the image holds stays unread while the forget waits for the writer, when a record of another type with its id arrives; that record reads its own row")
    func aForgottenIDIsLiftedOnlyByItsKey() async throws {
        let first = launch()
        try await seed(first)

        let second = launch(releaseBufferSize: 0)
        readAndSweep(Fixture(page: 1), in: second)
        let list = Fixture.plan.resolve(Fixture(page: 1).variables, in: second.store.keys)
        let deletion = try Ingest.normalize(fixture("delete-record-1"), plan: TestDeleteNote.plan.resolve(TestDeleteNote(id: "1").variables, in: second.store.keys), rootKey: Store.mutationRootKey)
        // Albert Einstein, whose origin is `Location:1`.
        let einstein = try Ingest.normalize(fixture("character-header-11"), plan: header("11", in: second.store))
        let origin = TestConditions.plan.resolve(TestConditions(id: "11", withOrigin: true, hideStatus: false).variables, in: second.store.keys)
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

    /// An image that holds the fixture's list and the root field
    /// `character(id: "5")`, which links to Jerry Smith.
    func seedJerry() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixture("character-header-5"), plan: header("5", in: first.store)))
        try await seed(first)
    }

    @Test("an observer that asks the store from inside a check's notification sees the whole walk: the slot it observes is filled, and so is every record after it")
    func anObserverSeesAWholeWalk() async throws {
        try await seedJerry()

        let second = launch()
        let store = second.store
        let plan = header("5", in: store)
        let slot = plan.variant(for: store.root.type).fields[0].slot
        @MainActor final class Seen {
            var fired = 0
            var value: Value?
            var hydratedRecords: Int?
            var answer: Store.Answer?
        }
        let seen = Seen()
        withObservationTracking { _ = store.root.read(slot) } onChange: {
            MainActor.assumeIsolated {
                seen.fired += 1
                seen.value = store.root.read(slot)
                seen.hydratedRecords = store.hydratedRecords
                seen.answer = store.check(plan)
            }
        }
        #expect(store.check(plan) == .image)
        #expect(seen.fired == 1, "the root field came from the image")
        #expect(seen.value.map { if case .ref = $0 { true } else { false } } == true, "the observed slot holds its link when it notifies")
        #expect(seen.hydratedRecords == 2, "Jerry and his origin were read before the notification, not after it")
        #expect(seen.answer == .image, "the question the observer asks is answered whole")
        #expect(store.hydratedRecords == 2, "the observer's question read nothing more")
        await finish(second)
    }

    @Test("a check notifies each slot it fills on a record a reader holds once, and none it already held")
    func aCheckNotifiesEachFilledSlotOnce() async throws {
        try await seedJerry()

        let second = launch()
        let store = second.store
        // Jerry's header from the network: memory holds some of his fields,
        // the image holds the rest.
        store.commit(try Ingest.normalize(fixture("character-header-5"), plan: header("5", in: store)))
        let jerry = try #require(store.existing("Character:5"))
        let held = Set(jerry.storedSlots.map(\.slot.index))
        let list = Fixture.plan.resolve(Fixture(page: 1).variables, in: store.keys)
        guard case .linked(let page, _, _, _) = list.variant(for: store.root.type).fields[0].kind,
              let results = page.variant(for: page.type).fields.first(where: { $0.responseKey == "results" }),
              case .linked(let character, _, _, _) = results.kind
        else {
            Issue.record("the list's plan reads characters' results")
            return
        }
        let slots = character.variant(for: jerry.type).fields.filter { $0.responseKey != "__typename" }.map(\.slot)
        let observers = slots.map { slot in
            let notifications = Notifications()
            notifications.track { _ = jerry.read(slot) }
            return (slot, notifications)
        }
        // His origin, which a reader holds too, is on no path the check
        // walks, and the episodes the check reads held nothing a reader saw.
        let origin = try #require(store.existing("Location:20"))
        let originSlots = origin.storedSlots.map(\.slot)
        let originObserver = Notifications()
        originObserver.track { for slot in originSlots { _ = origin.read(slot) } }
        let recordsBefore = store.count

        #expect(store.check(TestEpisodesQuery.plan.resolve(TestEpisodesQuery(id: "5").variables, in: store.keys)) == .image)
        var filled = 0
        for (slot, notifications) in observers {
            if held.contains(slot.index) {
                #expect(notifications.fired == 0, "a slot memory held is not notified")
            } else {
                if case .missing = jerry.read(slot) { continue }
                #expect(notifications.fired == 1, "a slot the image filled is notified once")
                filled += 1
            }
        }
        #expect(filled >= 4, "type, gender, created, location and episode came from the row")
        #expect(originObserver.fired == 0, "a record off the walk is not notified")
        #expect(store.count > recordsBefore, "the episodes came from the image, notifying no one")
        await finish(second)
    }

    @Test("data read every launch keeps its age: expired in the second launch, still dated and fresh in the third")
    func ageReadEveryLaunch() async throws {
        let transport = RecordedTransport { _ in fixtureData }
        let first = launch(transport)
        let fetched = first.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let fetchedRetention = fetched.retain()
        await fetched.settle()
        await finish(first)

        let second = launch(transport, cacheExpiration: .zero)
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
        withExtendedLifetime(fetchedRetention) {}
    }

    @Test("data read from the image without a fetch time is stale")
    func undatedDataIsStale() async throws {
        let transport = RecordedTransport { _ in fixtureData }
        let first = launch(transport)
        first.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: first.store.keys)))
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
        first.store.commit(try Ingest.normalize(fixture("character-null"), plan: header("999", in: first.store)))
        await finish(first)

        let transport = RecordedTransport { _ in fixture("character-null") }
        let second = launch(transport)
        _ = try stored(TestHeaderQuery(id: "999"), in: second)
        // Another operation on the same root field, which no launch fetched.
        let qualified = TestQualifiedQuery(id: "999")
        #expect(second.store.check(TestQualifiedQuery.plan.resolve(qualified.variables, in: second.store.keys)) == .image)
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
        let retention = handle.retain()
        _ = consume retention
        #expect(environment.store.collect() == 898)
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
        leaving.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: leaving.store.keys)))
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
        _ = store.check(Fixture.plan.resolve(Fixture(page: 1).variables, in: store.keys))
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

    @Test("removeAll deletes an image whether or not its file is open, and leaves a database of another kind at its path, told apart by an open or not")
    func removeAllDeletesOnlyAnImage() async throws {
        try await seed(launch())
        // Closed, as by a launch that has finished with it.
        let closed = Persistence(url: image.url)
        await closed.close()
        closed.removeAll()
        #expect(!FileManager.default.fileExists(atPath: image.url.path))

        var db: OpaquePointer?
        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE notes(text); INSERT INTO notes VALUES('mine')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let opened = Persistence(url: image.url)
        await opened.flush()
        opened.removeAll()
        await opened.close()
        // Whether a new image's first open or its removal takes the file
        // first is a race; a few rounds give the removal its turn.
        for _ in 0..<12 {
            let fresh = Persistence(url: image.url)
            fresh.removeAll()
            await fresh.close()
        }
        #expect(sqlite3_open_v2(image.url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "SELECT text FROM notes", nil, nil, nil) == SQLITE_OK, "the table is still there")
        sqlite3_close(db)
    }

    /// The protection class a file reports.
    func protection(of path: String) throws -> FileProtectionType? {
        try FileManager.default.attributesOfItem(atPath: path)[.protectionKey] as? FileProtectionType
    }

    @Test("an image made with a protection class carries it on its file and its write-ahead log")
    func protectionIsTheFiles() async throws {
        let environment = launch(protection: .complete)
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)))
        await environment.store.persistence?.flush()
        #expect(try protection(of: image.url.path) == .complete)
        #expect(FileManager.default.fileExists(atPath: image.url.path + "-wal"), "the log exists while the image is open")
        #expect(try protection(of: image.url.path + "-wal") == .complete)
        await finish(environment)

        let data = try stored(Fixture(page: 1), in: launch(protection: .complete))
        #expect(data.characters?.results?.first?.name == "Rick Sanchez", "the same class reads its rows")
    }

    @Test("an image made under another protection class is a miss and starts again under the new one, in either direction")
    func anotherProtectionStartsAgain() async throws {
        try await seed(launch())
        let protected = launch(protection: .complete)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: protected) }
        #expect(protected.store.hydratedRecords == 0)
        #expect(try protection(of: image.url.path) == .complete)
        try await seed(protected)
        let again = launch(protection: .complete)
        _ = try stored(Fixture(page: 1), in: again)
        await finish(again)

        let unprotected = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: unprotected) }
        #expect(unprotected.store.hydratedRecords == 0)
        await finish(unprotected)
    }

    @Test("a removal a crash interrupted is finished at the next open: the image is a miss and the marker goes")
    func anInterruptedRemovalIsFinished() async throws {
        try await seed(launch())
        #expect(FileManager.default.createFile(atPath: marker, contents: nil))
        let next = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: next) }
        #expect(next.store.hydratedRecords == 0)
        await next.store.persistence?.flush()
        #expect(!FileManager.default.fileExists(atPath: marker))
        await finish(next)
    }

    @Test("a marker beside a database of another kind leaves the database alone and goes, and the store works without an image")
    func aMarkerBesideAForeignDatabase() async throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE notes(text); INSERT INTO notes VALUES('mine')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(FileManager.default.createFile(atPath: marker, contents: nil))

        let environment = launch()
        environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)))
        await environment.store.persistence?.flush()
        #expect(!FileManager.default.fileExists(atPath: marker))
        _ = try stored(Fixture(page: 1), in: environment)
        await finish(environment)
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: launch()) }

        #expect(sqlite3_open(image.url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "SELECT text FROM notes", nil, nil, nil) == SQLITE_OK, "the table is still there")
        sqlite3_close(db)
    }

    @Test("a removal of an image whose file cannot be opened is marked, and the next open that can finishes it")
    func aRemovalOfAFileThatCannotBeOpened() async throws {
        try await seed(launch())
        try permit(0o000, [image.url.path])
        defer { try? permit(0o644, [image.url.path]) }

        let closed = Persistence(url: image.url)
        await closed.close()
        closed.removeAll()
        #expect(FileManager.default.fileExists(atPath: image.url.path), "the file could not be told an image, and stays")
        #expect(FileManager.default.fileExists(atPath: marker))

        try permit(0o644, [image.url.path])
        let next = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: next) }
        #expect(next.store.hydratedRecords == 0)
        #expect(!FileManager.default.fileExists(atPath: marker))
        await finish(next)
    }

    /// The fixture with Morty renamed, as a later response has it.
    var renamedFixture: Data {
        Data(String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"").utf8)
    }

    @Test("a response the user who signed out was waiting for lands after the end and the removal, and reaches neither the image nor the next user, whose own image took the same file")
    func aLateResponseAfterASignOut() async throws {
        let gate = GatedTransport()
        let leaving = launch(gate, version: "alice")
        let screen = leaving.handle(for: Fixture(page: 1))
        let screenRetention = screen.retain()
        await until { gate.pending == 1 }

        // The sign-out in its order: the environment ends, the image is
        // removed, and the next account makes its own image on the file.
        await leaving.end()
        leaving.store.persistence?.removeAll()
        let renamed = renamedFixture
        let transport = RecordedTransport { _ in renamed }
        let next = launch(transport, version: "bob")

        gate.respond(fixtureData)
        for _ in 0..<20 { await Task.yield() }
        withExtendedLifetime(screenRetention) {}

        let handle = next.handle(for: Fixture(page: 1))
        let retention = handle.retain()
        await handle.settle()
        #expect(transport.requestCount == 1, "the image had nothing to answer with")
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the next user's data, got \(handle.phase)")
            return
        }
        #expect(data.characters?.results?[1].name == "Morty C-137")
        withExtendedLifetime(retention) {}
        await finish(next)

        let later = launch(version: "bob")
        let reread = try stored(Fixture(page: 1), in: later)
        #expect(reread.characters?.results?[1].name == "Morty C-137", "the rows the next user's fetch wrote, not the late response")
        await finish(later)
    }

    @Test("an environment that ended before removeAll reads nothing from the next user's image, and its invalidation leaves the next user's data fresh")
    func aSignedOutStoreLeavesTheImageAlone() async throws {
        let leaving = launch(version: "alice")
        await leaving.end()
        leaving.store.persistence?.removeAll()
        let next = launch(RecordedTransport { _ in fixtureData }, version: "bob")
        let handle = next.handle(for: Fixture(page: 1))
        let retention = handle.retain()
        await handle.settle()
        await next.store.persistence?.flush()

        #expect(leaving.store.check(Fixture.plan.resolve(Fixture(page: 1).variables, in: leaving.store.keys)) == .miss, "the next user's rows")
        leaving.invalidate()
        await leaving.store.persistence?.flush()
        withExtendedLifetime(retention) {}
        await finish(next)

        let later = launch(version: "bob")
        let reread = later.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        guard case .ready = reread.phase else {
            Issue.record("expected the next user's rows, got \(reread.phase)")
            return
        }
        #expect(!reread.isStale, "the next user's fetch time stands")
        await finish(later)
    }

    @Test("after the end, removeAll deletes the file, and a new image on the same path in a new environment starts empty, reads nothing and writes its own rows for the next launch")
    func anImageAfterTheEndStartsAgainOnItsFile() async throws {
        let leaving = await signedIn(as: "", at: image.url)
        await leaving.end()
        let persistence = try #require(leaving.store.persistence)
        #expect(FileManager.default.fileExists(atPath: persistence.url.path))
        persistence.removeAll()
        #expect(!FileManager.default.fileExists(atPath: persistence.url.path), "the file is deleted")

        let renamed = renamedFixture
        let transport = RecordedTransport { _ in renamed }
        let next = Environment(transport: transport, store: Store(persistence: Persistence(url: persistence.url)))
        next.store.reportMissing = nil
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: next) }
        #expect(next.store.hydratedRecords == 0, "the new image reads nothing")
        try await next.fetch(Fixture(page: 1))
        await finish(next)

        let later = launch()
        let data = try stored(Fixture(page: 1), in: later)
        #expect(data.characters?.results?[1].name == "Morty C-137", "the rows the new image wrote")
        await finish(later)
    }

    @Test("a response that lands after the end reaches neither memory nor the image: a handle's refetch, and a fetch awaited in a task of the app's own")
    func aResponseAfterTheEnd() async throws {
        try await seed(launch())
        let gate = GatedTransport()
        let environment = launch(gate)
        let handle = environment.handle(for: Fixture(page: 1))
        let retention = handle.retain()
        await until { gate.pending == 1 }
        let own = Task { try await environment.fetch(TestList(page: 2)) }
        await until { gate.pending == 2 }

        await environment.end()
        gate.respond(renamedFixture)
        gate.respond(shiftedFixture(by: 200_000))
        _ = await own.result
        for _ in 0..<20 { await Task.yield() }
        #expect(environment.store.count == 3, "the store holds its three roots and none of the responses' records")
        #expect(environment.store.existing("Character:200001") == nil)
        guard case .failed(let error as EnvironmentError) = handle.phase, error == .gone else {
            Issue.record("expected the handle to fail on gone, got \(handle.phase)")
            return
        }
        withExtendedLifetime(retention) {}

        let next = launch()
        let data = try stored(Fixture(page: 1), in: next)
        #expect(data.characters?.results?[1].name == "Morty Smith", "the image holds what the seed wrote, not the late refetch")
        #expect(throws: NotStored.self) { try stored(TestList(page: 2), in: next) }
        await finish(next)
    }

    @Test("a mutation in flight at the end that the server answers reaches neither memory nor the image")
    func aMutationAnsweredAfterTheEnd() async throws {
        try await seed(launch())
        let gate = GatedTransport()
        let environment = launch(gate)
        // A launch that reads the list keeps its rows for the next one.
        _ = try stored(Fixture(page: 1), in: environment)
        let mutation = Task { try await environment.mutate(TestRename(id: "1", name: "Rick Prime")) }
        await until { gate.pending == 1 }

        await environment.end()
        gate.respond(fixture("rename-1"))
        _ = await mutation.result
        #expect(environment.store.existing("Character:1") == nil, "the store holds no record of the payload")
        #expect(environment.store.count == 3)

        let next = launch()
        let data = try stored(Fixture(page: 1), in: next)
        #expect(data.characters?.results?[0].name == "Rick Sanchez", "the image never took the rename")
        await finish(next)
    }

    /// Fetches the fixture as `account` on `url` and keeps the launch open,
    /// as a session that is about to sign out.
    func signedIn(as account: String, at url: URL) async -> Environment {
        let environment = launch(RecordedTransport { _ in fixtureData }, at: url, version: account)
        let handle = environment.handle(for: Fixture(page: 1))
        let retention = handle.retain()
        await handle.settle()
        await environment.store.persistence?.flush()
        withExtendedLifetime(retention) {}
        return environment
    }

    @Test("each step of a sign-out leaves nothing another account can read: after the end, another account reads nothing and the same account still reads its data; after removeAll, neither does")
    func theSignOutOrder() async throws {
        // The end alone: the image stays, under its account's version, so
        // the same account reads it again and another reads nothing.
        let ended = TemporaryImage()
        await signedIn(as: "alice", at: ended.url).end()
        let returning = launch(at: ended.url, version: "alice")
        let kept = try stored(Fixture(page: 1), in: returning)
        #expect(kept.characters?.results?.first?.name == "Rick Sanchez", "the cache survives a switch of accounts")
        await finish(returning)
        let bob = launch(at: ended.url, version: "bob")
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: bob) }
        #expect(bob.store.hydratedRecords == 0)
        await finish(bob)

        // The end, then removeAll; forgetting the credential is the app's,
        // with no step here.
        let alice = await signedIn(as: "alice", at: image.url)
        await alice.end()
        alice.store.persistence?.removeAll()
        let other = launch(version: "bob")
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: other) }
        await finish(other)
        let again = launch(version: "alice")
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: again) }
        await finish(again)
    }

    /// Asks `environment`, whose image does not hold the file, for its late
    /// work on it: a read, a commit and a removal, none of which may touch
    /// the file.
    func lateWork(in environment: Environment) async throws {
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: environment) }
        environment.store.commit(try Ingest.normalize(renamedFixture, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)))
        await environment.store.persistence?.flush()
        environment.store.persistence?.removeAll()
        #expect(FileManager.default.fileExists(atPath: image.url.path), "the file is the other image's")
    }

    @Test("an image that closed runs without its file once another image has taken it: it reads nothing from it, writes nothing to it and removes nothing")
    func aClosedImageWhoseFileWasTaken() async throws {
        let first = launch()
        await finish(first)
        let second = launch()
        second.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: second.store.keys)))
        await second.store.persistence?.flush()
        try await lateWork(in: first)
        await finish(first)
        await finish(second)

        let data = try stored(Fixture(page: 1), in: launch())
        #expect(data.characters?.results?[1].name == "Morty Smith", "the rows the second image wrote")
    }

    /// The image's path spelled the other way: through `/private`, where
    /// macOS keeps `/var` and `/tmp`, or without it. Foundation's
    /// standardized path drops `/private` only once the file exists.
    var otherSpelling: URL { Self.otherSpelling(of: image.url) }

    nonisolated static func otherSpelling(of url: URL) -> URL {
        let path = url.path
        return URL(fileURLWithPath: path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path)
    }

    /// A file of its own for an exit test, made in the child process: the
    /// testing library of the oldest supported Xcode takes no capture list
    /// in an exit test's closure.
    nonisolated static func childImage() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "baton-claim-\(UUID().uuidString).sqlite")
    }

    #if DEBUG
    @Test("a second image made on a file another image in the process holds stops a debug build where it is made")
    func aSecondImageStopsADebugBuild() async {
        await #expect(processExitsWith: .failure) {
            let url = Self.childImage()
            let first = Persistence(url: url)
            let second = Persistence(url: url)
            withExtendedLifetime((first, second)) {}
        }
    }

    @Test("a second image made on the file under another spelling of its path stops a debug build, before the file exists and after")
    func aSecondSpellingStopsADebugBuild() async {
        await #expect(processExitsWith: .failure) {
            let url = Self.childImage()
            let first = Persistence(url: url)
            let second = Persistence(url: Self.otherSpelling(of: url))
            withExtendedLifetime((first, second)) {}
        }
        await #expect(processExitsWith: .failure) {
            let other = Self.otherSpelling(of: Self.childImage())
            let first = Persistence(url: other)
            await first.flush()
            let second = Persistence(url: other)
            withExtendedLifetime((first, second)) {}
        }
    }
    #else
    @Test("a second image made on a file another image in the process holds runs without it, and its close leaves the file to the first")
    func aSecondImageRunsWithoutTheFile() async throws {
        let first = launch()
        first.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: first.store.keys)))
        await first.store.persistence?.flush()
        let second = launch()
        try await lateWork(in: second)
        await finish(second)
        let third = launch()
        #expect(throws: NotStored.self) { try stored(Fixture(page: 1), in: third) }
        await finish(third)
        await finish(first)

        let data = try stored(Fixture(page: 1), in: launch())
        #expect(data.characters?.results?[1].name == "Morty Smith", "the rows the first image wrote")
    }

    @Test("a second image made with the first's URL spelled through /private, once the file exists, runs without it, and the rows the first wrote reach the next launch")
    func aSecondSpellingRunsWithoutTheFile() async throws {
        // Made before the file exists, then again after, under the spelling
        // Foundation standardizes differently once the file is there.
        let first = launch(at: otherSpelling)
        first.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: first.store.keys)))
        await first.store.persistence?.flush()
        let second = launch(at: otherSpelling)
        try await lateWork(in: second)
        await finish(second)
        await finish(first)

        let data = try stored(Fixture(page: 1), in: launch())
        #expect(data.characters?.results?[1].name == "Morty Smith", "the rows the first image wrote, in the launch before")
    }
    #endif

    @Test("an image that is gone gives its file back, and the next image on the file reads what it wrote")
    func aGoneImageGivesItsFileBack() async throws {
        weak var gone: Persistence?
        do {
            let environment = launch()
            gone = environment.store.persistence
            environment.store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: environment.store.keys)))
            await environment.store.persistence?.flush()
        }
        await until { gone == nil }
        let data = try stored(Fixture(page: 1), in: launch())
        #expect(data.characters?.results?[1].name == "Morty Smith")
    }

    @Test("an image closed right behind its commit gives its file to the next, though the drain the commit scheduled may run after the close")
    func closedRightBehindACommit() async throws {
        // Kept alive, so an image that took its file again would keep it.
        var closed: [Environment] = []
        for _ in 0..<12 {
            let environment = launch()
            try commitUnknown(environment)
            await finish(environment)
            closed.append(environment)
        }
        try await seed(launch())
        _ = try stored(Fixture(page: 1), in: launch())
        withExtendedLifetime(closed) {}
    }

    @Test("a file damaged between a commit and a check is a miss, not a crash")
    func damagedUnderAnOpenConnection() async throws {
        // Whether the check or the writer meets the damage first is a race;
        // a few rounds give the check its turn.
        for _ in 0..<12 {
            let image = TemporaryImage()
            let first = Store(persistence: Persistence(url: image.url))
            first.reportMissing = nil
            first.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: first.keys)))
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
            first.commit(try Ingest.normalize(Data(renamed.utf8), plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: first.keys)))
            let second = Store(persistence: first.persistence)
            second.reportMissing = nil
            #expect(second.check(Fixture.plan.resolve(Fixture(page: 1).variables, in: second.keys)) == .miss)
            await first.persistence?.flush()
        }
    }

    @Test("an image made by name lives under the owner's directory, so two apps naming theirs alike do not share a file")
    func anImageByNameLivesUnderItsOwner() async {
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        #expect(Bundle.main.bundleIdentifier == nil, "the test runner has no bundle identifier; its process name keeps it apart")
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let expected = caches.appendingPathComponent(owner).appendingPathComponent("Baton").appendingPathComponent("Main.sqlite")
        let directory = expected.deletingLastPathComponent()
        let existed = FileManager.default.fileExists(atPath: expected.path)
        let directoryExisted = FileManager.default.fileExists(atPath: directory.path)

        let persistence = Persistence(name: "Main")
        #expect(Array(persistence.url.pathComponents.suffix(3)) == [owner, "Baton", "Main.sqlite"])
        #expect(persistence.url.standardizedFileURL.path == expected.standardizedFileURL.path)

        // Making the value opens its file; one this test created goes with it.
        await persistence.close()
        guard !existed else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: expected.path + suffix)
        }
        if !directoryExisted { try? FileManager.default.removeItem(at: directory) }
    }
}
