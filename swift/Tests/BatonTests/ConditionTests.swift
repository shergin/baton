@_spi(Generated) import Baton
import Foundation
import Testing

@MainActor
@Suite("Types and conditions", .timeLimit(.minutes(1)))
struct ConditionTests {
    /// A store whose missing reads are recorded.
    final class Misses: @unchecked Sendable {
        var reads: [String] = []
    }

    func store(_ misses: Misses) -> Store {
        let store = Store()
        store.log = { event in if case .missing(let type, let field) = event { misses.reads.append(type + "." + field) } }
        return store
    }

    @Test("@include and @skip select fields both ways: the check passes on the operation's own response, and a field a condition left out reads nil without a report")
    func includeAndSkip() throws {
        let fetched = TestConditions(id: "1", withOrigin: true, hideStatus: false)
        let misses = Misses()
        let full = store(misses)
        full.commit(try Ingest.normalize(fixture("conditions-included"), plan: TestConditions.plan.resolve(fetched.variables, in: full.keys)))
        #expect(full.check(TestConditions.plan.resolve(fetched.variables, in: full.keys)) != .miss)
        let shown = try #require(TestConditions.Data(anchor: Anchor(record: full.root, variables: fetched.variables, store: full)).character)
        #expect(shown.origin?.id == "1")
        #expect(shown.origin?.name == "Earth (C-137)")
        #expect(shown.status == "Alive")
        #expect(shown.species == "Human")

        let skipped = TestConditions(id: "1", withOrigin: false, hideStatus: true)
        let partial = store(misses)
        partial.commit(try Ingest.normalize(fixture("conditions-excluded"), plan: TestConditions.plan.resolve(skipped.variables, in: partial.keys)))
        #expect(partial.check(TestConditions.plan.resolve(skipped.variables, in: partial.keys)) != .miss, "a skipped field is not waited for")
        let hidden = try #require(TestConditions.Data(anchor: Anchor(record: partial.root, variables: skipped.variables, store: partial)).character)
        #expect(hidden.origin?.id == "1")
        #expect(hidden.origin?.name == nil)
        #expect(hidden.status == nil)
        #expect(hidden.species == nil)
        #expect(misses.reads.isEmpty, "nothing a condition left out is reported missing: \(misses.reads)")
    }

    @Test("a union reads each member by its own fields, one alias reads each type's own field, and an interface some members implement reads on those")
    func unionMembers() throws {
        let search = TestUnion(name: "a")
        let misses = Misses()
        let store = store(misses)
        store.commit(try Ingest.normalize(fixture("union-1"), plan: TestUnion.plan.resolve(search.variables, in: store.keys)))
        #expect(store.check(TestUnion.plan.resolve(search.variables, in: store.keys)) != .miss)
        let results = try #require(TestUnion.Data(anchor: Anchor(record: store.root, variables: search.variables, store: store)).search)
        #expect(results.count == 3)
        #expect(results[0].asCharacter?.label == "Rick Sanchez")
        #expect(results[0].asCharacter?.status == "Alive")
        #expect(results[1].asLocation?.label == "Dimension C-137", "the alias reads the Location's dimension")
        #expect(results[1].asLocation?.type == "Planet")
        #expect(results[2].asEpisode?.air_date == "December 2, 2013")
        #expect(results[0].asNamed?.name == "Rick Sanchez")
        #expect(results[1].asNamed?.name == "Earth (C-137)", "the name is not the alias's dimension")
        #expect(results[2].asNamed == nil, "an Episode is not Named")
        #expect(results[0].asLocation == nil)
        #expect(misses.reads.isEmpty, "\(misses.reads)")
    }

    @Test("a record of a type the build did not list takes the variant of the conditions the response says it satisfies")
    func unlistedTypeTakesTheConditionsVariant() throws {
        let search = TestUnion(name: "robot")
        let misses = Misses()
        let store = store(misses)
        store.commit(try Ingest.normalize(fixture("union-unknown-type"), plan: TestUnion.plan.resolve(search.variables, in: store.keys)))
        let results = try #require(TestUnion.Data(anchor: Anchor(record: store.root, variables: search.variables, store: store)).search)
        #expect(results.count == 2)
        #expect(results[0].asNamed?.name == "Butter Robot")
        #expect(results[0].asCharacter == nil, "a Robot is not a Character")
        #expect(results[0].asLocation == nil)
        #expect(results[1].asCharacter?.label == "Rick Sanchez")
        #expect(results[1].asNamed?.name == "Rick Sanchez")
        let robot = Registry.type("Robot")
        let record = try #require(store.existing("Robot:r1"), "the Robot is keyed by its id")
        #expect(record.read(Registry.slot(robot, "name")) == .string("Butter Robot"))
        #expect(record.read(Registry.slot(robot, "id")) == .string("r1"))
        #expect(misses.reads.isEmpty, "\(misses.reads)")
    }

    @Test("a type condition is answered by the compiled members and by what a response said")
    func membershipIsCompiledOrLearned() throws {
        // A type of its own: what a response says is learned for the
        // process, and another test commits the fixture's Robot.
        let name = "Robot_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let response = Data(String(decoding: fixture("union-unknown-type"), as: UTF8.self).replacingOccurrences(of: "\"Robot\"", with: "\"\(name)\"").utf8)
        let robot = Registry.type(name)
        #expect(!Types.Named_possible.includes(robot), "the build did not list it")
        #expect(Types.Named_possible.includes(Registry.type("Character")))
        #expect(Types.Named_possible.includes(Registry.type("Location")))
        #expect(!Types.Named_possible.includes(Registry.type("Episode")))

        let search = TestUnion(name: "robot")
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(response, plan: TestUnion.plan.resolve(search.variables, in: store.keys)))
        #expect(Types.Named_possible.includes(robot), "the response said it is Named")
        #expect(Types.Named_possible.includes(Registry.type("Character")))
        #expect(!Types.Named_possible.includes(Registry.type("Episode")), "learning one type adds no other")
    }

    @Test("an abstract selection reads its own fields on whatever type the record has")
    func abstractOwnFields() throws {
        for (response, name) in [("node-fields-character", "Rick Sanchez" as String?), ("node-fields-episode", nil)] {
            let node = TestNodeFields(id: "1")
            let store = Store()
            store.log = nil
            store.commit(try Ingest.normalize(fixture(response), plan: TestNodeFields.plan.resolve(node.variables, in: store.keys)))
            #expect(store.check(TestNodeFields.plan.resolve(node.variables, in: store.keys)) != .miss)
            let data = try #require(TestNodeFields.Data(anchor: Anchor(record: store.root, variables: node.variables, store: store)).node)
            #expect(data.id == "1")
            #expect(data.asCharacter?.name == name)
        }
    }

    @Test("a fragment spread twice reads through one accessor, and once more under a condition through its alias")
    func twoSpreads() throws {
        let store = Store()
        store.log = nil
        for again in [true, false] {
            let operation = TestTwoSpreads(id: "1", again: again)
            store.commit(try Ingest.normalize(fixture("two-spreads-1"), plan: TestTwoSpreads.plan.resolve(operation.variables, in: store.keys)))
            let character = try #require(TestTwoSpreads.Data(anchor: Anchor(record: store.root, variables: operation.variables, store: store)).character)
            #expect(character.testRow.name == "Rick Sanchez")
            #expect((character.again != nil) == again)
        }
    }

    @Test("a caught field under a condition keeps its error to itself, an uncaught one fails an operation that throws, and a field the condition left out has none")
    func caughtUnderCondition() throws {
        let fetched = TestStrictConditions(id: "1", withStatus: true)
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("strict-conditions-caught"), plan: TestStrictConditions.plan.resolve(fetched.variables, in: store.keys)))
        let anchor = Anchor(record: store.root, variables: fetched.variables, store: store)
        #expect(TestStrictConditions.Data.fieldErrors(anchor).map(\.message) == ["species is private"], "the caught status and origin keep theirs")
        #expect(throws: FieldErrors.self) { try TestStrictConditions.Data.throwing(anchor) }
        let character = try #require(TestStrictConditions.Data(anchor: anchor).character)
        guard case .failure(let status)? = character.status, case .failure(let origin)? = character.origin else {
            Issue.record("each caught field reads its own error")
            return
        }
        #expect(status.errors.map(\.message) == ["status is private"])
        #expect(origin.errors.map(\.message) == ["origin name is private"], "a caught link holds the errors inside it")

        let unselected = TestStrictConditions(id: "1", withStatus: false)
        let left = Anchor(record: store.root, variables: unselected.variables, store: store)
        #expect(TestStrictConditions.Data.fieldErrors(left).isEmpty, "the species error is on a field the condition left out")
        let plain = try #require(try TestStrictConditions.Data.throwing(left).character)
        #expect(plain.status == nil)
        #expect(plain.species == nil)
    }

    @Test("a fragment on an interface spread under another reads on every type that implements it, and on no other")
    func spreadOnAnInterface() throws {
        for (file, id, name) in [("node-fields-character", "1", "Rick Sanchez" as String?), ("node-fields-episode", "1", nil)] {
            let store = Store()
            store.log = nil
            let query = TestNamedSpread(id: id)
            store.commit(try Ingest.normalize(fixture(file), plan: TestNamedSpread.plan.resolve(query.variables, in: store.keys)))
            let node = try #require(TestNamedSpread.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).node)
            #expect(node.named?.name == name, "\(file)")
            #expect((node.named != nil) == (name != nil), "\(file)")
        }
    }

    @Test("a type condition every type the parent admits satisfies folds into the parent's lens")
    func conditionThatAlwaysHolds() throws {
        let store = Store()
        store.log = nil
        let query = TestFoldedNode(name: "1")
        store.commit(try Ingest.normalize(fixture("search-1"), plan: TestFoldedNode.plan.resolve(query.variables, in: store.keys)))
        let results = try #require(TestFoldedNode.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).search)
        let ids: [String?] = results.map(\.id)
        #expect(ids == ["1", "1", "1"], "every SearchResult is a Node, so `id` reads on the result itself")
    }
}
