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
}
