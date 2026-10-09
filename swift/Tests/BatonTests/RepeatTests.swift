@_spi(Generated) import Baton
import BatonSpec
import Foundation
import Testing

/// An entity object printed before under the same selection, byte for byte,
/// is read as the earlier object's record by a compare of its bytes, without
/// a parse, and `ChangeSet.repeats` counts the objects read so. The store is
/// what reading every object in full makes, which the manifest's cases hold
/// for each of their responses; these tests hold where the compare applies
/// and where it must not.
@MainActor
@Suite("Repeated objects", .timeLimit(.minutes(1)))
struct RepeatTests {
    /// The connection the edge directives name. No store holds it: the
    /// tests of an edit read the change set alone.
    let connections = ["Character:1:__TestNotes_notes_connection"]

    @Test func the_fixtures_entity_objects_printed_before_under_their_selection_are_read_as_repeats() throws {
        let store = Store()
        let changes = try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(Fixture(page: 1).variables, in: store.keys))
        // The count a walk of the fixture by the plan gives: 191 of the 242
        // episode objects under `results.episode`; 440 of the 1,266 characters
        // under the 51 episodes read in full, since a repeated episode's
        // characters are passed over with it; and 21 of the 40 origins and
        // locations, which share one selection. The 11 origins and locations
        // printed with a null id are keyed by their path and never repeat.
        #expect(changes.repeats == 652)
        // The records are those a full read makes: the dump's, but for the
        // roots of the mutation and the subscription, which the store adds.
        let dump = try #require(try JSONSerialization.jsonObject(with: Spec.data("rickandmorty/characters-page-1.store.json")) as? [String: Any])
        #expect(changes.recordKeys.count == 899)
        #expect(Set(changes.recordKeys) == Set(dump.keys).subtracting([Store.mutationRootKey, Store.subscriptionRootKey]))
        // The store after the commit is the dump, as the oracle proves for
        // every case of the manifest.
        store.commit(changes)
        StoreDump.expectMatches(store, "rickandmorty/characters-page-1")
    }

    @Test func an_entity_printed_twice_under_a_selection_with_an_edge_directive_is_read_in_full_both_times() throws {
        let store = Store()
        let mutation = TestAppendCastNodes(id: "1", name: "Rick Sanchez", connections: connections)
        let changes = try Ingest.normalize(fixture("rename-1-pilot-twice-with-cast"), plan: TestAppendCastNodes.plan.resolve(mutation.variables, in: store.keys), rootKey: Store.mutationRootKey)
        // The pilot is printed twice, byte for byte, under a selection that
        // holds `characters @appendNode`: each printing is read, and each
        // records the insertion of its cast, as a read of every object does.
        #expect(changes.repeats == 0)
        #expect(insertedNodes(changes) == ["Character:1", "Character:1"])
    }

    @Test func an_entity_printed_twice_in_a_plural_field_with_an_edge_directive_is_inserted_twice() throws {
        let store = Store()
        let mutation = TestAppendEpisodeNodes(id: "1", name: "Rick Sanchez", connections: connections)
        let changes = try Ingest.normalize(fixture("rename-1-pilot-twice"), plan: TestAppendEpisodeNodes.plan.resolve(mutation.variables, in: store.keys), rootKey: Store.mutationRootKey)
        // The edge directive is on `episode`, a field of the character's
        // selection: the character is read in full, and its reading inserts
        // each element of the list, however the element was read. The
        // episode's own selection records no edit, so its second printing is
        // a repeat, and it is inserted twice all the same.
        #expect(changes.repeats == 1)
        #expect(insertedNodes(changes) == ["Episode:1", "Episode:1"])
    }

    @Test func an_entity_printed_again_under_an_abstract_selection_is_read_as_a_repeat() throws {
        let store = Store()
        let query = TestUnion(name: "robot")
        let changes = try Ingest.normalize(fixture("union-unknown-type-twice"), plan: TestUnion.plan.resolve(query.variables, in: store.keys))
        // The union's elements print a robot, of a type the build did not
        // list, read by the memberships it answers, and a character, of a
        // type the union lists, each twice: each second printing is a repeat.
        #expect(changes.repeats == 2)
        store.commit(changes)
        let search = try #require(TestUnion.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).search)
        #expect(search.count == 4)
        #expect(search.element(2)?.recordID == search.element(0)?.recordID)
        #expect(search.element(3)?.recordID == search.element(1)?.recordID)
        #expect(search.element(2)?.asNamed?.name == "Butter Robot", "the robot's memberships, read from its first printing, hold for the repeat")
    }

    /// The keys of the records the change set's `@appendNode` and
    /// `@prependNode` edits insert, in their order.
    func insertedNodes(_ changes: ChangeSet) -> [String] {
        changes.edits.compactMap { edit in
            guard case .insertNode(let node, _, _, _) = edit else { return nil }
            return changes.recordKeys[Int(node)]
        }
    }
}
