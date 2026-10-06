@_spi(Generated) import Baton
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
        store.commit(try Ingest.normalize(fixture("search-1"), plan: TestSearch.plan.resolve(TestSearch(name: "1").variables, in: store.keys)))
        store.commit(try Ingest.normalize(fixture("characters-7-8"), plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        return store
    }

    @Test("@deleteRecord of an id three types share reports it and deletes nothing; of an id one record has, deletes that record")
    func deleteByBareID() throws {
        let ambiguities = Ambiguities()
        let store = try store(ambiguities)
        let shared = TestRemoveNote(id: "1", connections: [])
        store.commit(try Ingest.normalize(fixture("remove-note-1"), plan: TestRemoveNote.plan.resolve(shared.variables, in: store.keys), rootKey: Store.mutationRootKey))
        #expect(ambiguities.ids == ["1"])
        for key in ["Character:1", "Location:1", "Episode:1"] {
            #expect(store.existing(key)?.deleted == false, "\(key) is not deleted")
        }

        let unique = TestRemoveNote(id: "7", connections: [])
        store.commit(try Ingest.normalize(fixture("remove-note-7"), plan: TestRemoveNote.plan.resolve(unique.variables, in: store.keys), rootKey: Store.mutationRootKey))
        #expect(store.existing("Character:7")?.deleted == true)
        #expect(store.existing("Character:8")?.deleted == false)
        #expect(ambiguities.ids == ["1"])
    }

    @Test("a lookup without a type finds an id among its field's possible types only when one live record has it")
    func lookupWithoutAType() throws {
        let ambiguities = Ambiguities()
        let store = try store(ambiguities)
        #expect(store.check(TestNode.plan.resolve(TestNode(id: "1").variables, in: store.keys)) == .miss, "three types have the id 1")
        #expect(ambiguities.ids == ["1"])
        #expect(store.check(TestNode.plan.resolve(TestNode(id: "8").variables, in: store.keys)) != .miss)
        let data = TestNode.Data(anchor: Anchor(record: store.root, variables: TestNode(id: "8").variables, store: store))
        #expect(data.node?.asCharacter?.name == "Adjudicator Rick")
    }

    @Test("a lookup without a type probes the members the build compiled")
    func lookupProbesTheCompiledMembers() {
        let members = Set(Types.Node_possible.types.map(\.name))
        #expect(members == ["Character", "Episode", "Location", "Note"], "the schema's implementers of Node")
        #expect(Types.Node_possible.condition == Types.Node)
    }

    @Test("an object under a union keyed by its path is a record per concrete type, so another type at the same path does not share one")
    func pathKeysCarryTheType() throws {
        let store = Store()
        store.reportMissing = nil
        let search = TestUnion(name: "a")
        let plan = TestUnion.plan.resolve(search.variables, in: store.keys)
        let data = TestUnion.Data(anchor: Anchor(record: store.root, variables: search.variables, store: store))
        store.commit(try Ingest.normalize(fixture("union-path-character"), plan: plan))
        let first = try #require(data.search?.first)
        #expect(first.recordID.key == #"client:root:search(name:"a"):0:Character"#)
        #expect(first.asCharacter?.label == "Rick Sanchez")

        store.commit(try Ingest.normalize(fixture("union-path-location"), plan: plan))
        let second = try #require(data.search?.first)
        #expect(second.recordID.key == #"client:root:search(name:"a"):0:Location"#)
        #expect(second.asLocation?.label == "Dimension C-137")
        #expect(second.asCharacter == nil)
        #expect(store.existing(#"client:root:search(name:"a"):0:Character"#)?.type == Registry.type("Character"), "the first record kept its type")
    }

    // MARK: Configured identity

    /// Commits a response of `operation` into the store at the query root.
    func commit<Op: Baton.Operation>(_ name: String, _ operation: Op, into store: Store) throws {
        store.commit(try Ingest.normalize(fixture(name), plan: Op.plan.resolve(operation.variables, in: store.keys)))
    }

    @Test("two operations reaching an asset by different paths write one record, and each lens reads what the other fetched")
    func two_operations_reaching_an_asset_by_different_paths_write_one_record() throws {
        let store = Store()
        store.reportMissing = nil
        let list = TestAssetsQuery()
        let single = TestAssetQuery(uuid: "a1")
        try commit("asset-list", list, into: store)
        try commit("asset-by-uuid", single, into: store)

        let assets = store.recordsByKey.keys.filter { $0.hasPrefix("Asset:") }.sorted()
        #expect(assets == ["Asset:a1", "Asset:b2"], "the asset the second operation reached after its owner is the list's Asset:a1")
        let record = try #require(store.existing("Asset:a1"))
        #expect(record.read(Slots.Asset.size) == .int(3))

        let listed = TestAssetsQuery.Data(anchor: Anchor(record: store.root, variables: list.variables, store: store))
        #expect(listed.assets?.element(0)?.name == "Portal gun")
        #expect(listed.assets?.element(0)?.recordID.key == "Asset:a1")
        let reached = TestAssetQuery.Data(anchor: Anchor(record: store.root, variables: single.variables, store: store))
        #expect(reached.asset?.recordID.key == "Asset:a1")
        #expect(reached.asset?.owner?.name == "Rick Sanchez")
        let sized = try #require(reached.asset.map { TestAssetsQuery.Data.Assets(anchor: $0.anchor) })
        #expect(sized.size == 3, "the size the list fetched reads through the record the single asset reached")
    }

    @Test("a quote keyed by two fields is one record across a list and a lookup by the pair, and the later commit's rate wins")
    func a_quote_keyed_by_two_fields_is_one_record_across_a_list_and_a_lookup() throws {
        let store = Store()
        store.reportMissing = nil
        let list = TestQuotesQuery()
        try commit("quote-list", list, into: store)
        #expect(store.existing("Quote:BTC:USD")?.read(Slots.Quote.rate) == .double(1.5))
        try commit("quote-by-pair", TestQuoteQuery(base: "BTC", quote: "USD"), into: store)

        let quotes = store.recordsByKey.keys.filter { $0.hasPrefix("Quote:") }.sorted()
        #expect(quotes == [#"Quote:A\:B:C\\D"#, "Quote:BTC:USD", "Quote:EUR:USD"])
        #expect(store.existing("Quote:BTC:USD")?.read(Slots.Quote.rate) == .double(1.6))
        let data = TestQuotesQuery.Data(anchor: Anchor(record: store.root, variables: list.variables, store: store))
        #expect(data.quotes?.element(0)?.rate == 1.6)
        #expect(data.quotes?.element(0)?.recordID.key == "Quote:BTC:USD")
    }

    @Test("a composite key escapes the backslashes and colons of each value, and a key of one value is written raw")
    func a_composite_key_escapes_its_values_and_a_single_value_stays_raw() throws {
        let store = Store()
        store.reportMissing = nil
        try commit("quote-list", TestQuotesQuery(), into: store)
        let escaped = try #require(store.existing(#"Quote:A\:B:C\\D"#), "base A:B and quote C\\D")
        #expect(escaped.read(Slots.Quote.base) == .string("A:B"))
        #expect(escaped.read(Slots.Quote.quote) == .string(#"C\D"#))

        // A type and a root field of their own, so that no other test
        // writes the record.
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let keyed = Registry.type("Raw_" + suffix)
        let query = Registry.type("Query")
        let fieldName = "raw" + suffix
        let plan = Plan(root: Selection(type: query, key: [], fields: [
            .linked(fieldName, key: .fixed(Registry.slot(query, fieldName)), plural: false, selection: Selection(type: keyed, key: ["id"], fields: [
                .scalar("id", key: .fixed(Registry.slot(keyed, "id")), kind: .string, list: false),
            ])),
        ]))
        let response = Data(#"{"data":{"\#(fieldName)":{"id":"1:2"}}}"#.utf8)
        store.commit(try Ingest.normalize(response, plan: plan.resolve(.none, in: store.keys)))
        #expect(store.existing(keyed.name + ":1:2") != nil, "one value is written as it is, colon and all")
    }

    @Test("the compiler selects the configured key fields an operation leaves out")
    func the_compiler_selects_the_configured_key_fields_an_operation_leaves_out() {
        #expect(TestAssetsQuery.text.contains("    uuid\n"), "\(TestAssetsQuery.text)")
        #expect(TestQuotesQuery.text.contains("    base\n"), "\(TestQuotesQuery.text)")
        #expect(TestQuotesQuery.text.contains("    quote\n"), "\(TestQuotesQuery.text)")
    }
}
