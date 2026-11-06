@_spi(Generated) import Baton
import Foundation
import Testing

/// What the ingest does with an entity's object the response prints again
/// under one selection: a printing equal byte for byte to an earlier one is
/// taken as that printing's record, and anything else is read as before.
@MainActor
@Suite("An entity printed again")
struct RepeatTests {
    /// The response's notes page for each character, as the plain and the
    /// connection documents both select it; Rick's printing comes again
    /// after Morty's, byte for byte. Rick's page has no edges, so no entity
    /// below him is printed twice and the only repeat is his own object.
    static let repeatedNotes: Data = {
        let rick = #"{"id":"1","notes":{"edges":[],"pageInfo":{"endCursor":null,"hasNextPage":false}}}"#
        let morty = #"{"id":"2","notes":{"edges":[{"cursor":"c1","node":{"__typename":"Note","id":"n5","text":"Aw geez"}}],"pageInfo":{"endCursor":"c1","hasNextPage":false}}}"#
        return Data((#"{"data":{"characters":{"results":["# + rick + "," + morty + "," + rick + "]}}}").utf8)
    }()

    @Test("the recorded page takes 652 objects by comparing and appends their first printings' entries again, 20,572 before grouping")
    func theRecordedPageTakesItsRepeatsByComparing() throws {
        let store = Store()
        store.log = nil
        let operation = Fixture(page: 1)
        let changes = try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(operation.variables, in: store.keys))
        #expect(changes.skipped == 652)
        #expect(changes.entriesBeforeGrouping == 20572)
    }

    @Test("a printing whose members come in another order is read whole and settles as the one record")
    func aReorderedPrintingIsReadWhole() throws {
        let store = Store()
        store.log = nil
        let operation = TestRepeatedCharacters(page: 1)
        let changes = try Ingest.normalize(fixture("repeated-character-reordered"), plan: TestRepeatedCharacters.plan.resolve(operation.variables, in: store.keys))
        #expect(changes.skipped == 0)
        store.commit(changes)
        let list = try #require(store.existing("client:root:characters(page:1)"))
        guard case .refs(let refs) = list.read(Registry.slot(list.type, "results")) else {
            Issue.record("the results hold no list")
            return
        }
        #expect(refs.map { $0?.key } == ["Character:1", "Character:2", "Character:1"])
    }

    @Test("an entity printed twice with different values under one selection reads the second printing's values")
    func theSecondPrintingsValuesWin() throws {
        let response = Data(#"{"data":{"characters":{"results":[{"id":"1","name":"Rick Sanchez","status":"Alive"},{"id":"1","name":"Rick Prime","status":"Dead"}]}}}"#.utf8)
        let store = Store()
        store.log = nil
        let operation = TestRepeatedCharacters(page: 1)
        let changes = try Ingest.normalize(response, plan: TestRepeatedCharacters.plan.resolve(operation.variables, in: store.keys))
        #expect(changes.skipped == 0)
        store.commit(changes)
        let rick = try #require(store.existing("Character:1"))
        #expect(rick.read(Registry.slot(rick.type, "name")) == .string("Rick Prime"))
        #expect(rick.read(Registry.slot(rick.type, "status")) == .string("Dead"))
    }

    @Test("an entity printed three times, the third equal to the first byte for byte, reads the third printing's values")
    func theLastPrintingsValuesWinWhenTheyRepeatAnEarlierOne() throws {
        // Each printing runs past the 64 bytes the ingest hashes, so the
        // third is found by its bytes alone and not by what follows it.
        let first = #"{"id":"1","name":"Rick Sanchez of Earth, Dimension C-137","status":"Alive"}"#
        let second = #"{"id":"1","name":"Rick Prime of an Earth no portal reaches","status":"Dead"}"#
        let response = Data((#"{"data":{"characters":{"results":["# + first + "," + second + "," + first + "]}}}").utf8)
        let store = Store()
        store.log = nil
        let operation = TestRepeatedCharacters(page: 1)
        let changes = try Ingest.normalize(response, plan: TestRepeatedCharacters.plan.resolve(operation.variables, in: store.keys))
        store.commit(changes)
        let rick = try #require(store.existing("Character:1"))
        #expect(rick.read(Registry.slot(rick.type, "name")) == .string("Rick Sanchez of Earth, Dimension C-137"))
        #expect(rick.read(Registry.slot(rick.type, "status")) == .string("Alive"))
    }

    @Test("an entity printed again under a selection with a connection below it is read whole")
    func aRepeatAboveAConnectionIsReadWhole() throws {
        let store = Store()
        store.log = nil
        let operation = TestRepeatedConnectionNotes()
        let changes = try Ingest.normalize(Self.repeatedNotes, plan: TestRepeatedConnectionNotes.plan.resolve(operation.variables, in: store.keys))
        #expect(changes.skipped == 0)
    }

    @Test("the same entity printed again under the same selection without the connection is taken by comparing")
    func aRepeatWithoutTheConnectionIsTakenByComparing() throws {
        let store = Store()
        store.log = nil
        let operation = TestRepeatedPlainNotes()
        let changes = try Ingest.normalize(Self.repeatedNotes, plan: TestRepeatedPlainNotes.plan.resolve(operation.variables, in: store.keys))
        #expect(changes.skipped == 1)
        store.commit(changes)
        let list = try #require(store.existing("client:root:characters(page:1)"))
        guard case .refs(let refs) = list.read(Registry.slot(list.type, "results")) else {
            Issue.record("the results hold no list")
            return
        }
        #expect(refs.map { $0?.key } == ["Character:1", "Character:2", "Character:1"])
    }

    /// The connection the edge directives name. No store holds it: the
    /// tests of an edit read the change set alone.
    static let connections = ["Character:1:__TestNotes_notes_connection"]

    @Test("an entity printed twice under a selection whose plural field carries an edge directive is read whole both times")
    func aRepeatAboveAnEdgeDirectiveIsReadWhole() throws {
        let store = Store()
        store.log = nil
        let mutation = TestAppendCastNodes(id: "1", name: "Rick Sanchez", connections: Self.connections)
        let changes = try Ingest.normalize(fixture("rename-1-pilot-twice-with-cast"), plan: TestAppendCastNodes.plan.resolve(mutation.variables, in: store.keys), rootKey: Store.mutationRootKey)
        // The pilot is printed twice, byte for byte, under a selection that
        // holds `characters @appendNode`: each printing records the insertion
        // of its cast.
        #expect(changes.skipped == 0)
        #expect(Self.insertedNodes(changes) == ["Character:1", "Character:1"])
    }

    @Test("an entity printed twice in a plural field that carries an edge directive is taken by comparing and inserted twice")
    func aRepeatBelowAnEdgeDirectiveIsTakenAndInsertedTwice() throws {
        let store = Store()
        store.log = nil
        let mutation = TestAppendEpisodeNodes(id: "1", name: "Rick Sanchez", connections: Self.connections)
        let changes = try Ingest.normalize(fixture("rename-1-pilot-twice"), plan: TestAppendEpisodeNodes.plan.resolve(mutation.variables, in: store.keys), rootKey: Store.mutationRootKey)
        // The directive is on `episode`, a field of the character's
        // selection: the episode's own selection records no edit, so its
        // second printing is taken by comparing, and the character's reading
        // inserts each element of the list all the same.
        #expect(changes.skipped == 1)
        #expect(Self.insertedNodes(changes) == ["Episode:1", "Episode:1"])
    }

    @Test("an entity printed again under an abstract selection, of a type the plan did not list or one it did, is taken by comparing")
    func aRepeatUnderAnAbstractSelectionIsTakenByComparing() throws {
        let store = Store()
        store.log = nil
        let query = TestUnion(name: "robot")
        let changes = try Ingest.normalize(fixture("union-unknown-type-twice"), plan: TestUnion.plan.resolve(query.variables, in: store.keys))
        // A robot, of a type the build did not list and read by the
        // memberships it answers, and a character, each printed twice.
        #expect(changes.skipped == 2)
        store.commit(changes)
        let results = try #require(TestUnion.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).search)
        #expect(results.count == 4)
        #expect(results[2].asNamed?.name == "Butter Robot", "the robot's memberships, read from its first printing, hold for the repeat")
        #expect(results[2].asCharacter == nil)
        #expect(results[3].asCharacter?.label == "Rick Sanchez")
    }

    /// The keys of the records the change set's `@appendNode` and
    /// `@prependNode` edits insert, in their order.
    static func insertedNodes(_ changes: ChangeSet) -> [String] {
        changes.edits.compactMap { edit in
            guard case .insertNode(let node, _, _, _) = edit else { return nil }
            return changes.recordKeys[Int(node)]
        }
    }
}
