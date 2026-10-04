import Baton
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
        store.reportMissing = { record, slot in misses.reads.append(record.key + "." + slot.storageKey) }
        return store
    }

    @Test("@include and @skip select fields both ways: the check passes on the operation's own response, and a field a condition left out reads nil without a report")
    func includeAndSkip() throws {
        let fetched = TestConditions(id: "1", withOrigin: true, hideStatus: false)
        let misses = Misses()
        let full = store(misses)
        full.commit(try Ingest.normalize(fixture("conditions-included"), plan: TestConditions.plan.resolve(fetched.variables)))
        #expect(full.check(TestConditions.plan.resolve(fetched.variables)))
        let shown = try #require(TestConditions.Data(anchor: Anchor(record: full.root, variables: fetched.variables, store: full)).character)
        #expect(shown.origin?.id == "1")
        #expect(shown.origin?.name == "Earth (C-137)")
        #expect(shown.status == "Alive")
        #expect(shown.species == "Human")

        let skipped = TestConditions(id: "1", withOrigin: false, hideStatus: true)
        let partial = store(misses)
        partial.commit(try Ingest.normalize(fixture("conditions-excluded"), plan: TestConditions.plan.resolve(skipped.variables)))
        #expect(partial.check(TestConditions.plan.resolve(skipped.variables)), "a skipped field is not waited for")
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
        store.commit(try Ingest.normalize(fixture("union-1"), plan: TestUnion.plan.resolve(search.variables)))
        #expect(store.check(TestUnion.plan.resolve(search.variables)))
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

    @Test("an abstract selection reads its own fields on whatever type the record has")
    func abstractOwnFields() throws {
        for (response, name) in [("node-fields-character", "Rick Sanchez" as String?), ("node-fields-episode", nil)] {
            let node = TestNodeFields(id: "1")
            let store = Store()
            store.reportMissing = nil
            store.commit(try Ingest.normalize(fixture(response), plan: TestNodeFields.plan.resolve(node.variables)))
            #expect(store.check(TestNodeFields.plan.resolve(node.variables)))
            let data = try #require(TestNodeFields.Data(anchor: Anchor(record: store.root, variables: node.variables, store: store)).node)
            #expect(data.id == "1")
            #expect(data.asCharacter?.name == name)
        }
    }

    @Test("a fragment spread twice reads through one accessor, and once more under a condition through its alias")
    func twoSpreads() throws {
        let store = Store()
        store.reportMissing = nil
        for again in [true, false] {
            let operation = TestTwoSpreads(id: "1", again: again)
            store.commit(try Ingest.normalize(fixture("two-spreads-1"), plan: TestTwoSpreads.plan.resolve(operation.variables)))
            let character = try #require(TestTwoSpreads.Data(anchor: Anchor(record: store.root, variables: operation.variables, store: store)).character)
            #expect(character.testRow.name == "Rick Sanchez")
            #expect((character.again != nil) == again)
        }
    }

    @Test("a caught field under a condition keeps its error to itself, an uncaught one fails an operation that throws, and a field the condition left out has none")
    func caughtUnderCondition() throws {
        let fetched = TestStrictConditions(id: "1", withStatus: true)
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixture("strict-conditions-caught"), plan: TestStrictConditions.plan.resolve(fetched.variables)))
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
            store.reportMissing = nil
            let query = TestNamedSpread(id: id)
            store.commit(try Ingest.normalize(fixture(file), plan: TestNamedSpread.plan.resolve(query.variables)))
            let node = try #require(TestNamedSpread.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).node)
            #expect(node.named?.name == name, "\(file)")
            #expect((node.named != nil) == (name != nil), "\(file)")
        }
    }
}
