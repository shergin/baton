@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

@MainActor
@Suite("Input objects", .timeLimit(.minutes(1)))
struct InputTests {
    /// The storage key the root's first field renders under `variables`.
    func rootKey(_ plan: Plan, _ variables: Variables) throws -> String {
        let field = try #require(plan.root.variants.first?.fields.first)
        guard case .dynamic(let key) = field.key else {
            Issue.record("the root field's key reads no variable")
            return ""
        }
        return key.render(variables)
    }

    @Test("an input object's struct renders the fields it was given, sorted, and leaves out the ones left absent")
    func aStructRendersItsSetFieldsAndLeavesAbsentOnesOut() {
        let filter = FilterCharacter(name: "Rick", status: "Alive")
        #expect(filter.variable.json == #"{"name":"Rick","status":"Alive"}"#)
        #expect(FilterCharacter().variable == .object([:]))
    }

    @Test("an operation's variable that is a list of input objects carries the objects its structs render")
    func aListOfStructsIsCarriedAsAListOfObjects() {
        let query = TestFilteredCharacters(filters: [FilterCharacter(status: "Alive")])
        #expect(query.variables.json == #"{"filters":[{"status":"Alive"}]}"#)
    }

    @Test("a storage key rendered from an input struct is the text the same object written as a variable rendered")
    func aStorageKeyFromAStructIsTheTextOfTheObject() throws {
        let query = TestFilteredCharacters(filters: [FilterCharacter(name: "Rick", status: "Alive")])
        let written = Variables(["filters": .list([.object(["name": .string("Rick"), "status": .string("Alive")])])])
        let key = try rootKey(TestFilteredCharacters.plan, query.variables)
        #expect(key == #"charactersMatching(filters:[{"name":"Rick","status":"Alive"}])"#)
        #expect(key == (try rootKey(TestFilteredCharacters.plan, written)))
    }

    @Test("a document that writes an input object as a constant with a variable inside keys the field as the fixture's store does")
    func aDocumentPassingAnInputConstantStillKeysItsField() throws {
        let store = Store()
        store.reportMissing = nil
        let query = TestKeys(id: "7", name: "Rick")
        store.commit(try Ingest.normalize(fixture("keys-1"), plan: TestKeys.plan.resolve(query.variables, in: store.keys)))
        let keys = store.root.storedSlots.map { store.storageKey(of: $0.slot) }
        #expect(keys.contains(#"characters(filter:{"name":"Rick","status":"Alive"})"#), "\(keys)")
        let data = TestKeys.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.characters?.info?.count == 1)
    }
}
