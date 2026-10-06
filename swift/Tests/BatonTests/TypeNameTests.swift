@_spi(Generated) import Baton
import BatonInspector
import Foundation
import Testing

/// The `__typename` of an object under an abstract selection: a name the plan
/// lists is matched as bytes, and every other spelling, an escaped one or a
/// name the plan does not list, resolves through the registry as before.
/// That a listed name ingests as `spec/` freezes it is proved by the oracle
/// cases `tests/search-1` and `tests/union-1`.
@MainActor
@Suite("The type name of an abstract object", .timeLimit(.minutes(1)))
struct TypeNameTests {
    /// The store after one search response is committed through `TestSearch`.
    func searchStore(_ response: Data) throws -> Store {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(response, plan: TestSearch.plan.resolve(TestSearch(name: "1").variables, in: store.keys)))
        return store
    }

    func searchResults(_ store: Store) throws -> [TestSearch.Data.Search] {
        let data = TestSearch.Data(anchor: Anchor(record: store.root, variables: TestSearch(name: "1").variables, store: store))
        return Array(try #require(data.search))
    }

    @Test("a listed type spelled with a json escape resolves to the same type, key and fields as the plain spelling")
    func an_escaped_listed_type_name_resolves_as_the_plain_one() throws {
        let escaped = Data(#"""
            {"data":{"search":[
              {"__typename":"Character","id":"1","name":"Rick Sanchez"},
              {"id":"1","name":"Earth (C-137)","dimension":"Dimension C-137","__typename":"Location"},
              {"__typename":"Episode","id":"1","name":"Pilot"}
            ]}}
            """#.utf8)
        let plain = try searchStore(fixture("search-1"))
        let store = try searchStore(escaped)

        let record = try #require(store.existing("Character:1"), "the escaped name keys the record as a Character")
        #expect(record.type == Registry.type("Character"))
        #expect(record.type.name == "Character")
        let results = try searchResults(store)
        #expect(results.count == 3)
        #expect(results[0].recordID.key == "Character:1")
        #expect(results[0].asCharacter?.id == "1")
        #expect(results[0].asCharacter?.name == "Rick Sanchez")
        #expect(results[0].asLocation == nil)
        #expect(results[1].asLocation?.dimension == "Dimension C-137")
        #expect(StoreExport.text(of: store) == StoreExport.text(of: plain), "the escaped spelling commits the store the plain one does")
    }

    @Test("a type the schema has that the plan does not list resolves through the registry, keys its record, and reads no condition's lens")
    func an_unlisted_type_name_resolves_through_the_registry() throws {
        let response = Data(#"{"data":{"node":{"__typename":"Location","id":"7"}}}"#.utf8)
        let node = TestNodeFields(id: "7")
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(response, plan: TestNodeFields.plan.resolve(node.variables, in: store.keys)))

        let record = try #require(store.existing("Location:7"), "the Location is keyed by its type and id")
        #expect(record.type == Registry.type("Location"))
        #expect(store.existing("Character:7") == nil)
        let data = try #require(TestNodeFields.Data(anchor: Anchor(record: store.root, variables: node.variables, store: store)).node)
        #expect(data.id == "7")
        #expect(data.asCharacter == nil, "a Location is not a Character")
    }

    @Test("a name one byte longer or shorter than a listed name, or of its length with one byte changed, is not the listed type", arguments: ["Characters", "Characte", "Charactex"])
    func a_near_miss_of_a_listed_name_is_an_unlisted_type(_ name: String) throws {
        let response = Data(#"{"data":{"search":[{"__typename":"\#(name)","id":"1","name":"Rick Sanchez"}]}}"#.utf8)
        let store = try searchStore(response)

        #expect(store.existing("Character:1") == nil, "\(name) is not a Character")
        let results = try searchResults(store)
        #expect(results.count == 1)
        // A type the plan does not list has no key the build knows of, so
        // its record is keyed by its path, which ends in the name sent.
        let key = results[0].recordID.key
        #expect(key.hasSuffix(":" + name))
        let record = try #require(store.existing(key))
        #expect(record.type.name == name, "the record's type is the name sent")
        #expect(record.type == Registry.type(name))
        #expect(results[0].asCharacter == nil)
        #expect(results[0].asLocation == nil)
    }
}
