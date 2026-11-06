@_spi(Generated) import Baton
import Foundation
import Observation
import Testing

/// Counts the notifications the observation scopes it starts receive.
@MainActor
final class Notifications {
    var fired = 0

    func track(_ read: @escaping @MainActor () -> Void) {
        withObservationTracking { read() } onChange: { [self] in
            MainActor.assumeIsolated { fired += 1 }
        }
    }
}

@MainActor
@Suite("One write path", .timeLimit(.minutes(1)))
struct WritePathTests {
    /// Normalizes a payload as an optimistic response would be, at a root.
    func changes<Op: Baton.Operation>(_ name: String, _ operation: Op, root: String = Store.rootKey, in store: Store) throws -> ChangeSet {
        try Ingest.normalize(fixture(name), plan: Op.plan.resolve(operation.variables, in: store.keys), rootKey: root)
    }

    @Test("a server's field error survives an optimistic write to the field that fails")
    func errorsAreUndone() throws {
        let store = Store()
        store.log = nil
        let profile = TestProfileQuery(id: "1")
        store.commit(try changes("character-errors", profile, in: store))
        let rick = try #require(store.existing("Character:1"))
        let image = Registry.slot(Registry.type("Character"), "image")
        #expect(rick.error(image) != nil)

        let layer = store.applyOptimistic(try changes("character-deferred-1", profile, in: store))
        #expect(rick.read(image) == .string("rick.png"))
        #expect(rick.error(image) == nil, "the layer answers the field")
        store.revertOptimistic(layer)
        #expect(rick.read(image) == .null)
        #expect(rick.error(image) == FieldError(message: "image service unavailable", path: "character.image"), "the error is back")
    }

    @Test("a record an optimistic response revives is deleted again when the layer fails")
    func revivalsAreUndone() async throws {
        let environment = Environment(transport: notesTransport())
        environment.log = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        let store = environment.store
        store.commit(try changes("delete-note-n2", TestDeleteNote(id: "n2"), root: Store.mutationRootKey, in: store))
        let note = try #require(store.existing("Note:n2"))
        #expect(note.deleted)

        let layer = store.applyOptimistic(try changes("add-note-n2", TestAddNote(characterId: "1", text: "Portal gun needs charging", connections: []), root: Store.mutationRootKey, in: store))
        #expect(!note.deleted, "the layer names the note again")
        store.revertOptimistic(layer)
        #expect(note.deleted, "and lifting it deletes it again")
        withExtendedLifetime(retention) {}
    }

    @Test("a server commit under a layer that deletes a record notifies nothing it did not change")
    func commitsUnderADeletionLayer() throws {
        let store = Store()
        store.log = nil
        let list = TestList(page: 1)
        store.commit(try changes("characters-7-8", list, in: store))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: list.variables, store: store))
        _ = store.applyOptimistic(try changes("delete-note-7", TestDeleteNote(id: "7"), root: Store.mutationRootKey, in: store))
        #expect(data.characters?.results?.count == 1)

        let notifications = Notifications()
        let abradolf = TestRow_character(anchor: Anchor(record: try #require(store.existing("Character:7")), variables: .none, store: store))
        notifications.track { _ = abradolf.name }
        notifications.track { _ = data.characters?.results }
        let changed = store.commit(try changes("characters-7-8", list, in: store))
        #expect(changed == 0)
        #expect(notifications.fired == 0, "lifting and laying the deletion again cancels out")
    }

    @Test("a body that reads only a connection's nodes is told when @deleteRecord deletes one, with no @deleteEdge")
    func deletionTellsConnections() async throws {
        let environment = Environment(transport: notesTransport())
        environment.log = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase, let character = data.character?.testNotes else {
            Issue.record("the first page did not arrive")
            return
        }
        #expect(character.notes.nodes.count == 2)
        let notifications = Notifications()
        notifications.track { _ = character.notes.nodes }
        environment.store.commit(try changes("delete-note-n2", TestDeleteNote(id: "n2"), root: Store.mutationRootKey, in: environment.store))
        #expect(notifications.fired == 1)
        #expect(character.notes.nodes.map(\.id) == ["n1"])
        withExtendedLifetime(retention) {}
    }

    @Test("a body that reads only a list is told when one of its records is deleted, and again when a payload revives it")
    func deletionTellsLists() throws {
        let store = Store()
        store.log = nil
        let list = TestList(page: 1)
        store.commit(try changes("characters-7-8", list, in: store))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: list.variables, store: store))
        let notifications = Notifications()
        notifications.track { _ = data.characters?.results }
        store.commit(try changes("delete-note-7", TestDeleteNote(id: "7"), root: Store.mutationRootKey, in: store))
        #expect(notifications.fired == 1)
        #expect(data.characters?.results?.count == 1)

        notifications.track { _ = data.characters?.results }
        store.commit(try changes("characters-7-8", list, in: store))
        #expect(notifications.fired == 2, "the revival is told too")
        #expect(data.characters?.results?.count == 2)
    }

    @Test("the ingest builds one record per key of its change set, and the commit adopts them and empties the box, the store reading back what the response holds")
    func theCommitAdoptsTheBuiltRecords() throws {
        let store = Store()
        store.log = nil
        let list = TestList(page: 1)
        let built = try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(list.variables, in: store.keys))
        #expect(built.prebuilt.count > 0)
        #expect(built.prebuilt.count == built.recordKeys.count)
        store.commit(built)
        #expect(built.prebuilt.count == 0, "the commit took the records")
        let roots: Set<String> = [Store.rootKey, Store.mutationRootKey, Store.subscriptionRootKey]
        #expect(store.count == roots.union(built.recordKeys).count, "a record for every key, beside the roots")

        let data = TestList.Data(anchor: Anchor(record: store.root, variables: list.variables, store: store))
        let rick = try #require(data.characters?.results?.first)
        #expect(rick.testRow.name == "Rick Sanchez")
        #expect(rick.testHeader.origin?.name == "Earth (C-137)")
        #expect(data.characters?.results?.count == 20)
    }

    @Test("a record a commit adopts links the records the store already held under the keys it names, not the ones the ingest built for them")
    func anAdoptedRecordLinksTheStoresRecords() throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let rick = try #require(store.existing("Character:1"))
        let morty = try #require(store.existing("Character:2"))
        #expect(store.existing("Episode:1") == nil)

        // The full page names the characters again and the episodes for the
        // first time; an episode links the characters.
        store.commit(try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: store.keys)))
        #expect(store.existing("Character:1") === rick)
        let pilot = try #require(store.existing("Episode:1"))
        guard case .refs(let cast) = pilot.read(Registry.slot(Registry.type("Episode"), "characters")) else {
            Issue.record("the episode holds no list of characters")
            return
        }
        #expect(cast.count > 2)
        #expect(cast[0] === rick, "the adopted episode links the store's own record")
        #expect(cast[1] === morty)
        // A record the store held links an adopted one through its entries.
        guard case .ref(let location) = rick.read(Registry.slot(Registry.type("Character"), "location")) else {
            Issue.record("the character holds no location")
            return
        }
        #expect(location === store.existing("Location:3"))
    }

    @Test("a record an optimistic layer created is emptied when the layer lifts, and a body that read it through a link is told and reads it as missing")
    func createdRecordsAreUndone() async throws {
        let environment = Environment(transport: notesTransport())
        environment.log = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase, let character = data.character?.testNotes else {
            Issue.record("the first page did not arrive")
            return
        }
        let store = environment.store
        #expect(store.existing("Note:n9") == nil)

        let added = TestAddNote(characterId: "1", text: "Appended", connections: [character.notes.connectionID])
        let layer = store.applyOptimistic(try changes("add-note-n9", added, root: Store.mutationRootKey, in: store))
        let appended = try #require(character.notes.nodes.last)
        #expect(appended.text == "Appended", "the layer made the note")
        let note = try #require(store.existing("Note:n9"))

        let notifications = Notifications()
        notifications.track { _ = appended.text }
        store.revertOptimistic(layer)
        #expect(notifications.fired == 1, "the body that read the created note is told")
        #expect(appended.text == nil)
        #expect(note.storedSlots.isEmpty, "the record holds nothing the layer wrote")
        #expect(character.notes.nodes.map(\.id) == ["n1", "n2"])
        withExtendedLifetime(retention) {}
    }
}
