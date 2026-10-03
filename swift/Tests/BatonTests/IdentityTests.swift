import Baton
import Foundation
import Testing

@MainActor
@Suite("Identity", .timeLimit(.minutes(1)))
struct IdentityTests {
    /// The ids a store reported as shared by more than one type.
    final class Ambiguities: @unchecked Sendable {
        var ids: [String] = []
    }

    /// A store holding Character:1, Location:1 and Episode:1, and Characters
    /// 7 and 8, recording the ids it reports as ambiguous.
    func store(_ ambiguities: Ambiguities) throws -> Store {
        let store = Store()
        store.reportMissing = nil
        store.reportAmbiguousIdentity = { id, _ in ambiguities.ids.append(id) }
        store.commit(try Ingest.normalize(fixture("search-1"), plan: TestSearch.plan.resolve(TestSearch(name: "1").variables)))
        store.commit(try Ingest.normalize(fixture("characters-7-8"), plan: TestList.plan.resolve(TestList(page: 1).variables)))
        return store
    }

    @Test("@deleteRecord of an id three types share reports it and deletes nothing; of an id one record has, deletes that record")
    func deleteByBareID() throws {
        let ambiguities = Ambiguities()
        let store = try store(ambiguities)
        let shared = TestRemoveNote(id: "1", connections: [])
        store.commit(try Ingest.normalize(fixture("remove-note-1"), plan: TestRemoveNote.plan.resolve(shared.variables), rootKey: Store.mutationRootKey))
        #expect(ambiguities.ids == ["1"])
        for key in ["Character:1", "Location:1", "Episode:1"] {
            #expect(store.existing(key)?.deleted == false, "\(key) is not deleted")
        }

        let unique = TestRemoveNote(id: "7", connections: [])
        store.commit(try Ingest.normalize(fixture("remove-note-7"), plan: TestRemoveNote.plan.resolve(unique.variables), rootKey: Store.mutationRootKey))
        #expect(store.existing("Character:7")?.deleted == true)
        #expect(store.existing("Character:8")?.deleted == false)
        #expect(ambiguities.ids == ["1"])
    }

    @Test("a lookup without a type finds an id among its field's possible types only when one live record has it")
    func lookupWithoutAType() throws {
        let ambiguities = Ambiguities()
        let store = try store(ambiguities)
        #expect(!store.check(TestNode.plan.resolve(TestNode(id: "1").variables)), "three types have the id 1")
        #expect(ambiguities.ids == ["1"])
        #expect(store.check(TestNode.plan.resolve(TestNode(id: "8").variables)))
        let data = TestNode.Data(anchor: Anchor(record: store.root, variables: TestNode(id: "8").variables, store: store))
        #expect(data.node?.asCharacter?.name == "Adjudicator Rick")
    }
}
