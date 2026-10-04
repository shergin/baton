@_spi(Generated) import Baton
import BatonSpec
import Foundation
import Observation
import Testing

@MainActor
@Suite("The vertical spine", .timeLimit(.minutes(1)))
struct SpineTests {
    @Test("ingesting the fixture and reading it through lenses agrees with the raw response")
    func theResponseIsTheOracle() throws {
        let store = Store()
        let variables = Fixture(page: 1).variables
        let changes = try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(variables))
        let changed = store.commit(changes)

        let tree = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        let rawResults = ((tree["data"] as! [String: Any])["characters"] as! [String: Any])["results"] as! [[String: Any]]

        #expect(store.count == 901, "898 entities and three roots")
        #expect(changed > 0)
        let data = Fixture.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let results = try #require(data.characters?.results)
        #expect(results.count == rawResults.count)
        for (lens, raw) in zip(results, rawResults) {
            #expect(lens.name == raw["name"] as? String)
            #expect(lens.image == raw["image"] as? String)
            #expect(lens.origin?.name == (raw["origin"] as? [String: Any])?["name"] as? String)
            #expect(lens.episode.count == (raw["episode"] as! [Any]).count)
        }
        #expect(data.characters?.info?.count == 826)
        #expect(data.characters?.info?.prev == nil)

        // The same entity reached by two paths is one record.
        let rick = results[0]
        let rickViaEpisode = try #require(results[0].episode.first?.characters.first { $0.name == "Rick Sanchez" })
        #expect(rick.recordID == rickViaEpisode.recordID)
    }

    @Test("a document under the module-qualified marker in a raw literal compiles and reads")
    func qualifiedMarker() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let query = TestQualifiedQuery(id: "1")
        #expect(store.check(TestQualifiedQuery.plan.resolve(query.variables)) != .miss)
        let data = TestQualifiedQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.character?.name == "Rick Sanchez")
    }

    @Test("a type named Types with fields named Type, Protocol and Baton compiles, and each field reads its own value")
    func namesTheGeneratedCodeUses() throws {
        let store = Store()
        let query = TestNames()
        store.commit(try Ingest.normalize(fixture("names-1"), plan: TestNames.plan.resolve(query.variables)))
        let types = try #require(TestNames.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).types)
        #expect(types.`Type` == "not a metatype")
        #expect(types.`Protocol` == "not a protocol")
        #expect(types.Baton == "not the module")
    }

    @Test("types named Baton, Type, Protocol and Set compile, and each record reads through the conditions it satisfies")
    func typesNamedLikeSwiftAndTheModule() throws {
        let store = Store()
        let query = TestSpellings()
        store.commit(try Ingest.normalize(fixture("spellings-1"), plan: TestSpellings.plan.resolve(query.variables)))
        let spellings = try #require(TestSpellings.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).spellings)
        #expect(spellings.map { $0.asSpelled?.label } == ["the module", "not a metatype", "not a protocol", "not a set", nil])
        #expect(spellings.map { $0.asBaton?.id } == ["1", nil, nil, nil, nil])
        #expect(spellings.map { $0.asType?.id } == [nil, "2", nil, nil, nil])
        #expect(spellings.map { $0.asProtocol?.id } == [nil, nil, "3", nil, nil])
        #expect(spellings.map { $0.asSet?.id } == [nil, nil, nil, "4", nil])
    }

    @Test("a character already in the store renders in the first body of its detail")
    func firstBodyFromCache() throws {
        let environment = Environment(transport: SilentTransport())
        let listVariables = TestList(page: 1).variables
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(listVariables)))

        // The detail's root field `character(id: "1")` was never fetched; the
        // check binds its lookup to the cached entity, synchronously.
        let cached = environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeAndNetwork)
        guard case .ready(let data) = cached.phase else {
            Issue.record("expected .ready on creation, got \(cached.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Rick Sanchez")
        #expect(data.character?.testHeader.origin?.name == "Earth (C-137)")
        #expect(cached.isRefreshing, "store-and-network still fetches")

        let absent = environment.handle(for: TestHeaderQuery(id: "999"))
        guard case .loading = absent.phase else {
            Issue.record("expected .loading for an entity the store never saw")
            return
        }
    }

    @Test("a commit that changes one field invalidates exactly one row")
    func oneFieldOneRow() throws {
        let store = Store()
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let rows = try #require(data.characters?.results)
        #expect(rows.count == 20)

        final class Counter: @unchecked Sendable { var fired: [String] = [] }
        let counter = Counter()
        for row in rows {
            let lens = row.testRow
            let key = lens.anchor.record.key
            withObservationTracking {
                _ = lens.name
                _ = lens.status
                _ = lens.image
            } onChange: {
                counter.fired.append(key)
            }
        }

        // Same payload again: nothing changes, nothing fires, nothing allocates for strings.
        let unchanged = store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))
        #expect(unchanged == 0)
        #expect(counter.fired.isEmpty)

        // Morty's name changes in the payload: one record, one row.
        let edited = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let changed = store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestList.plan.resolve(variables)))
        #expect(changed == 1)
        #expect(counter.fired == ["Character:2"])
        #expect(rows[1].testRow.name == "Morty C-137")
    }

    @Test("a body that reads one field of a record is invalidated by a commit that changes that field and by no other")
    func oneFieldOfOneRecord() throws {
        let store = Store()
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let morty = try #require(data.characters?.results?[1].testRow)
        #expect(morty.name == "Morty Smith")

        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        func track() {
            withObservationTracking { _ = morty.name } onChange: { counter.fired += 1 }
        }
        func commit(_ from: String, _ to: String) throws {
            let edited = String(decoding: fixtureData, as: UTF8.self).replacingOccurrences(of: from, with: to)
            store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestList.plan.resolve(variables)))
        }

        track()
        try commit(#""name":"Morty Smith","status":"Alive""#, #""name":"Morty Smith","status":"Dead""#)
        #expect(counter.fired == 0, "the status changed, which the body did not read")
        #expect(morty.status == "Dead")
        try commit(#""name":"Morty Smith""#, #""name":"Morty C-137""#)
        #expect(counter.fired == 1, "the name changed")
    }

    @Test("a field whose slot is a multiple of sixteen from the one a body reads does not invalidate it")
    func slotsSixteenApart() throws {
        let store = Store()
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let morty = try #require(data.characters?.results?[1].testRow)

        // A key of Character numbered at the name's place modulo sixteen,
        // where a pool of sixteen channels would put the two on one.
        let query = Registry.type("Query")
        let character = Registry.type("Character")
        let name = Registry.slot(character, "name")
        var probe = 0
        while Registry.slot(character, "probe\(probe)").index & 15 != name.index & 15 { probe += 1 }
        let sibling = Registry.slot(character, "probe\(probe)")
        let plan = Plan(root: Selection(type: query, hasID: false, fields: [
            .linked("probe", key: .fixed(Registry.slot(query, "probe")), plural: false, selection: Selection(type: character, hasID: true, fields: [
                .scalar("id", key: .fixed(Registry.slot(character, "id")), kind: .string, list: false),
                .scalar("probe\(probe)", key: .fixed(sibling), kind: .string, list: false),
            ])),
        ])).resolve(.none)

        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking { _ = morty.name } onChange: { counter.fired += 1 }
        store.commit(try Ingest.normalize(Data(#"{"data":{"probe":{"id":"2","probe\#(probe)":"written"}}}"#.utf8), plan: plan))
        #expect(store.existing("Character:2")?.read(sibling) == .string("written"))
        #expect(counter.fired == 0, "slot \(sibling.index) and the name's slot \(name.index) are channels apart")
    }

    @Test("keys rendered from variables, one per cursor, leave the dense numbering of their type alone, so a field first used after a hundred of them is stored beside the type's other fields")
    func renderedKeysAreNumberedApart() throws {
        // A type of its own, so that no other test numbers keys on it.
        let paged = Registry.type("Paged_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let query = Registry.type("Query")
        let id = Registry.slot(paged, "id")
        let items = DynamicKey(paged, [.literal("items(after:"), .variable("cursor"), .literal(")")])
        func cursor(_ number: Int) -> Variables { Variables(["cursor": .string("c\(number)")]) }
        let pages = (0..<100).map { Owner(variables: cursor($0)).slot(items) }
        let late = Registry.slot(paged, "late")
        #expect(id.index == 0)
        #expect(late.index == 1, "the dense keys of the type are id and late, whatever the cursors made")
        #expect(Set(pages.map(\.index)).count == 100, "each cursor's key has a slot of its own")

        let link = Registry.slot(query, "paged" + paged.name)
        let plan = Plan(root: Selection(type: query, hasID: false, fields: [
            .linked("paged", key: .fixed(link), plural: false, selection: Selection(type: paged, hasID: true, fields: [
                .scalar("id", key: .fixed(id), kind: .string, list: false),
                .scalar("late", key: .fixed(late), kind: .string, list: false),
                .scalar("items", key: .dynamic(items), kind: .string, list: false),
            ])),
        ])).resolve(cursor(57))
        let store = Store()
        store.commit(try Ingest.normalize(Data(#"{"data":{"paged":{"id":"1","late":"read","items":"page 57"}}}"#.utf8), plan: plan))
        let record = try #require(store.existing(paged.name + ":1"))
        #expect(record.read(late) == .string("read"))
        #expect(record.read(pages[57]) == .string("page 57"))
        #expect(record.read(pages[56]) == .missing)
    }

    @Test("root fields rendered from variables read back their own values whatever order they arrive in, and a commit of one wakes no body that read another")
    func renderedRootFieldsKeepTheirOwnValues() throws {
        let query = Registry.type("Query")
        let prefix = "spine_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = DynamicKey(query, [.literal(prefix + "(n:"), .variable("n"), .literal(")")])
        func variables(_ number: Int) -> Variables { Variables(["n": .int(number)]) }
        // Numbered in this order, written in the reverse one.
        let keys = (0..<10).map { Owner(variables: variables($0)).slot(key) }
        let plan = Plan(root: Selection(type: query, hasID: false, fields: [
            .scalar("field", key: .dynamic(key), kind: .string, list: false),
        ]))
        func commit(_ number: Int, _ value: String, into store: Store) throws {
            store.commit(try Ingest.normalize(Data(#"{"data":{"field":"\#(value)"}}"#.utf8), plan: plan.resolve(variables(number))))
        }
        let store = Store()
        for number in (0..<10).reversed() { try commit(number, "value \(number)", into: store) }
        #expect(keys.allSatisfy { $0.index < 0 }, "every rendering is numbered apart")
        #expect(keys.map { store.root.read($0) } == (0..<10).map { Value.string("value \($0)") })

        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking { _ = store.root.read(keys[3]) } onChange: { counter.fired += 1 }
        try commit(4, "changed", into: store)
        #expect(counter.fired == 0, "the body read another root field")
        try commit(3, "changed", into: store)
        #expect(counter.fired == 1)
        #expect(store.root.read(keys[3]) == .string("changed"))
        #expect(store.root.read(keys[4]) == .string("changed"))
    }

    @Test("a field with constant arguments is numbered beside its type's fields without arguments and one with a variable apart, so the rows of a list keep the first among their dense values")
    func constantArgumentsAreNumberedDensely() throws {
        let operation = TestNoteCounts(page: 1, count: 98)
        let store = Store()
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(operation.variables)))
        let character = Registry.type("Character")
        // The slot the generated constant holds, and the one the commit's
        // owner rendered, which a lookup by its text finds.
        let pinned = Registry.slot(character, "notes(first:97)")
        let recent = Registry.slot(character, "notes(first:98)")
        #expect(pinned.index >= 0, "a constant is a dense slot, with arguments or without")
        #expect(recent.index < 0, "a key rendered from a variable is numbered apart")

        let data = TestNoteCounts.Data(anchor: Anchor(record: store.root, variables: operation.variables, store: store))
        let rows = try #require(data.characters?.results)
        #expect(rows.map(\.pinned.totalCount) == [3, 0])
        #expect(rows.map(\.recent.totalCount) == [3, 0])
    }

    @Test("a key keeps one slot in a process whichever way it is met first: a rendering of a constant's key reads what the constant wrote, and a constant met after a rendering reads what the rendering wrote")
    func aKeyHasOneSlotWhicheverWayItIsMet() throws {
        let store = Store()
        let written = TestNoteCounts(page: 1, count: 99)
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables)))

        // The plan met `notes(first:97)` as its constant; a count of 97
        // renders the same key.
        let rendering = TestNoteCounts(page: 1, count: 97)
        let data = TestNoteCounts.Data(anchor: Anchor(record: store.root, variables: rendering.variables, store: store))
        let rick = try #require(data.characters?.results?.first)
        #expect(rick.recent.totalCount == 3, "the rendering reads the constant's slot")

        // The commit rendered `notes(first:99)`; a constant of that text met
        // now is the same slot, numbered apart.
        let character = Registry.type("Character")
        let constant = Registry.slot(character, "notes(first:99)")
        #expect(constant.index < 0)
        let record = try #require(store.existing("Character:1"))
        guard case .ref(let connection) = record.read(constant) else {
            Issue.record("the constant reads no link: \(record.read(constant))")
            return
        }
        #expect(connection.read(Registry.slot(connection.type, "totalCount")) == .int(3))
    }

    @Test("a lens read never writes: a root field the store lacks reads nil until the check binds its lookup to the cached entity")
    func lookupBindsInTheCheck() throws {
        final class Misses: @unchecked Sendable { var reads: [String] = [] }
        let misses = Misses()
        let store = Store()
        store.reportMissing = { record, slot in misses.reads.append(record.key + "." + slot.storageKey) }
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables)))

        let detail = TestHeaderQuery(id: "3")
        let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: detail.variables, store: store))
        #expect(data.character == nil, "the read does not resolve the lookup")
        #expect(misses.reads == [#"client:root.character(id:"3")"#])
        guard case .missing = store.root.read(Registry.slot(store.root.type, #"character(id:"3")"#)) else {
            Issue.record("the read wrote the link")
            return
        }
        #expect(store.check(TestHeaderQuery.plan.resolve(detail.variables)) != .miss)
        #expect(data.character?.testHeader.name == "Summer Smith", "the check wrote the link")
    }

    @Test("an object whose id arrives after a link is keyed by its id, so a detail joins the entity the list fetched")
    func identityArrivesAfterALink() throws {
        final class Misses: @unchecked Sendable { var reads: [String] = [] }
        let misses = Misses()
        let store = Store()
        store.reportMissing = { record, slot in misses.reads.append(record.key + "." + slot.storageKey) }
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))

        // The detail's header renders from the store, through the lookup the
        // check binds.
        let header = TestHeaderQuery(id: "9")
        #expect(store.check(TestHeaderQuery.plan.resolve(header.variables)) != .miss)
        let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: header.variables, store: store))
        #expect(data.character?.testHeader.name == "Agency Director")

        // A second operation on the same root field answers first. Its `id` is
        // the one Relay adds, after the `episode` link, and the server sends
        // it there.
        let episodes = TestEpisodesQuery(id: "9")
        store.commit(try Ingest.normalize(Spec.data("rickandmorty/character-episodes-9.json"), plan: TestEpisodesQuery.plan.resolve(episodes.variables)))
        let character = try #require(data.character)
        #expect(character.recordID.key == "Character:9")
        #expect(store.existing(#"client:root:character(id:"9")"#) == nil, "no second record for the same entity")
        #expect(character.testHeader.name == "Agency Director")
        #expect(character.testHeader.origin?.name == "Earth (Replacement Dimension)")
        #expect(misses.reads.isEmpty)

        let episodesData = TestEpisodesQuery.Data(anchor: Anchor(record: store.root, variables: episodes.variables, store: store))
        #expect(episodesData.character?.episode.map { $0.name } == ["Pickle Rick"])

        // The header's own response carries the `id` last as well: it lands on
        // the same records and changes nothing.
        let count = store.count
        let changed = store.commit(try Ingest.normalize(Spec.data("rickandmorty/character-header-9.json"), plan: TestHeaderQuery.plan.resolve(header.variables)))
        #expect(changed == 0)
        #expect(store.count == count)
    }

    @Test("operation values hash by their variables only")
    func operationValueIdentity() {
        let a = TestHeaderQuery(id: "1")
        var b = TestHeaderQuery(id: "1")
        b.resolution = nil
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(TestHeaderQuery(id: "2") != a)
        #expect(TestHeaderQuery.persistedID.count == 32)
    }
}
