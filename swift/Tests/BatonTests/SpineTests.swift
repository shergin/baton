@_spi(Generated) import Baton
import BatonSpec
import BatonTesting
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
        let changes = try Ingest.normalize(fixtureData, plan: Fixture.plan.resolve(variables, in: store.keys))
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
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let query = TestQualifiedQuery(id: "1")
        #expect(store.check(TestQualifiedQuery.plan.resolve(query.variables, in: store.keys)) != .miss)
        let data = TestQualifiedQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.character?.name == "Rick Sanchez")
    }

    @Test("a type named Types with fields named Type, Protocol, Baton and Any compiles, and each field reads its own value")
    func namesTheGeneratedCodeUses() throws {
        let store = Store()
        let query = TestNames()
        store.commit(try Ingest.normalize(fixture("names-1"), plan: TestNames.plan.resolve(query.variables, in: store.keys)))
        let types = try #require(TestNames.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).types)
        #expect(types.`Type` == "not a metatype")
        #expect(types.`Protocol` == "not a protocol")
        #expect(types.Baton == "not the module")
        #expect(types.`Any` == "not any type")
    }

    @Test("a field named Baton in a lens under @catch compiles, and reads its value or the field errors in the lens")
    func caughtFieldNamedLikeTheModule() throws {
        let query = TestCaughtNames()
        let store = Store()
        store.commit(try Ingest.normalize(fixture("caught-names-1"), plan: TestCaughtNames.plan.resolve(query.variables, in: store.keys)))
        let data = TestCaughtNames.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(try data.types.get()?.Baton == "not the module")

        let failing = Store()
        failing.commit(try Ingest.normalize(fixture("caught-names-1-errors"), plan: TestCaughtNames.plan.resolve(query.variables, in: failing.keys)))
        let failed = TestCaughtNames.Data(anchor: Anchor(record: failing.root, variables: query.variables, store: failing))
        guard case .failure(let errors) = failed.types else {
            Issue.record("expected the error on Baton, got \(failed.types)")
            return
        }
        #expect(errors.errors == [FieldError(message: "the module is private", path: "types.Baton")])
    }

    @Test("types named Baton, Type, Protocol, Set and Any compile, and each record reads through the conditions it satisfies")
    func typesNamedLikeSwiftAndTheModule() throws {
        let store = Store()
        let query = TestSpellings()
        store.commit(try Ingest.normalize(fixture("spellings-1"), plan: TestSpellings.plan.resolve(query.variables, in: store.keys)))
        let spellings = try #require(TestSpellings.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).spellings)
        #expect(spellings.map { $0.asSpelled?.label } == ["the module", "not a metatype", "not a protocol", "not a set", "not any type", nil])
        #expect(spellings.map { $0.asBaton?.id } == ["1", nil, nil, nil, nil, nil])
        #expect(spellings.map { $0.asType?.id } == [nil, "2", nil, nil, nil, nil])
        #expect(spellings.map { $0.asProtocol?.id } == [nil, nil, "3", nil, nil, nil])
        #expect(spellings.map { $0.asSet?.id } == [nil, nil, nil, "4", nil, nil])
        #expect(spellings.map { $0.asAny?.id } == [nil, nil, nil, nil, "5", nil])
    }

    @Test("a character already in the store renders in the first body of its detail")
    func firstBodyFromCache() throws {
        let environment = Environment(transport: SilentTransport())
        let listVariables = TestList(page: 1).variables
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(listVariables, in: environment.store.keys)))

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
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables, in: store.keys)))
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
        let unchanged = store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables, in: store.keys)))
        #expect(unchanged == 0)
        #expect(counter.fired.isEmpty)

        // Morty's name changes in the payload: one record, one row.
        let edited = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let changed = store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestList.plan.resolve(variables, in: store.keys)))
        #expect(changed == 1)
        #expect(counter.fired == ["Character:2"])
        #expect(rows[1].testRow.name == "Morty C-137")
    }

    @Test("a body that reads one field of a record is invalidated by a commit that changes that field and by no other")
    func oneFieldOfOneRecord() throws {
        let store = Store()
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables, in: store.keys)))
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
            store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestList.plan.resolve(variables, in: store.keys)))
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
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables, in: store.keys)))
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
        let plan = Plan(root: Selection(type: query, key: nil, fields: [
            .linked("probe", key: .fixed(Registry.slot(query, "probe")), plural: false, selection: Selection(type: character, key: "id", fields: [
                .scalar("id", key: .fixed(Registry.slot(character, "id")), kind: .string, list: false),
                .scalar("probe\(probe)", key: .fixed(sibling), kind: .string, list: false),
            ])),
        ])).resolve(.none, in: store.keys)

        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking { _ = morty.name } onChange: { counter.fired += 1 }
        store.commit(try Ingest.normalize(Data(#"{"data":{"probe":{"id":"2","probe\#(probe)":"written"}}}"#.utf8), plan: plan))
        #expect(store.existing("Character:2")?.read(sibling) == .string("written"))
        #expect(counter.fired == 0, "slot \(sibling.index) and the name's slot \(name.index) are channels apart")
    }

    @Test("a type the build did not list that the response does not say is a member reads only the fields every type reads")
    func unlistedTypeWithoutAnAnswerReadsTheSharedFields() throws {
        // Types of their own, so that no other test settles their variants
        // or teaches the process their memberships.
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let query = Registry.type("Query")
        let shape = Registry.type("Shape_" + suffix)
        let rounded = Registry.type("Rounded_" + suffix)
        let circle = Registry.type("Circle_" + suffix)
        let blob = Registry.type("Blob_" + suffix)
        let disc = Registry.type("Disc_" + suffix)
        func field(_ type: TypeID, _ name: String) -> PlanField {
            .scalar(name, key: .fixed(Registry.slot(type, name)), kind: .string, list: false)
        }
        let plan = Plan(root: Selection(type: query, key: nil, fields: [
            .linked("shape", key: .fixed(Registry.slot(query, "shape_" + suffix)), plural: false, selection: Selection(type: shape, key: "id", abstract: true, memberships: [.init("__isRounded", rounded)], variants: [
                .init(types: [circle], fields: [field(circle, "__typename"), field(circle, "id"), field(circle, "label"), field(circle, "radius")]),
                .init(types: nil, condition: rounded, fields: [field(shape, "__typename"), field(shape, "id"), field(shape, "label"), field(shape, "radius")]),
                .init(types: nil, fields: [field(shape, "__typename"), field(shape, "id"), field(shape, "label")]),
            ])),
        ]))
        let store = Store()
        store.reportMissing = nil
        let resolved = plan.resolve(.none, in: store.keys)
        let payload = #"{"data":{"shape":{"__typename":"\#(blob.name)","id":"b1","label":"blob","radius":"3"}}}"#
        store.commit(try Ingest.normalize(Data(payload.utf8), plan: resolved))
        let record = try #require(store.existing("\(blob.name):b1"))
        #expect(record.read(Registry.slot(blob, "label")) == .string("blob"), "every type reads the shared field")
        #expect(record.read(Registry.slot(blob, "radius")) == .missing, "without the answer the condition's field is not stored")

        // The same payload with the answer, on another unlisted type.
        let answered = #"{"data":{"shape":{"__typename":"\#(disc.name)","__isRounded":"\#(disc.name)","id":"d1","label":"disc","radius":"3"}}}"#
        store.commit(try Ingest.normalize(Data(answered.utf8), plan: resolved))
        let other = try #require(store.existing("\(disc.name):d1"))
        #expect(other.read(Registry.slot(disc, "radius")) == .string("3"), "with the answer the condition's field is stored")
    }

    @Test("keys rendered from variables, one per cursor, are numbered by the store and leave the dense numbering of their type alone, so a field first used after a hundred of them is stored beside the type's other fields")
    func renderedKeysAreNumberedApart() throws {
        // A type of its own, so that no other test numbers keys on it.
        let paged = Registry.type("Paged_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let query = Registry.type("Query")
        let store = Store()
        let id = Registry.slot(paged, "id")
        let items = DynamicKey(paged, "items", [KeyArgument("after", [.variable("cursor")])])
        func cursor(_ number: Int) -> Variables { Variables(["cursor": .string("c\(number)")]) }
        let pages = (0..<100).map { Owner(variables: cursor($0), store: store).slot(items) }
        let late = Registry.slot(paged, "late")
        #expect(id.index == 0)
        #expect(late.index == 1, "the dense keys of the type are id and late, whatever the cursors made")
        #expect(Registry.slotCount(paged) == 2, "the process numbers only the build's keys")
        #expect(store.keys.count(on: paged) == 100, "the store numbers each cursor's key")
        #expect(pages.allSatisfy { $0.index < 0 }, "a rendered key is numbered apart")
        #expect(Set(pages.map(\.index)).count == 100, "each cursor's key has a slot of its own")
        #expect(store.storageKey(of: pages[57]) == #"items(after:"c57")"#, "the store names a slot it numbered")

        let link = Registry.slot(query, "paged" + paged.name)
        let plan = Plan(root: Selection(type: query, key: nil, fields: [
            .linked("paged", key: .fixed(link), plural: false, selection: Selection(type: paged, key: "id", fields: [
                .scalar("id", key: .fixed(id), kind: .string, list: false),
                .scalar("late", key: .fixed(late), kind: .string, list: false),
                .scalar("items", key: .dynamic(items), kind: .string, list: false),
            ])),
        ])).resolve(cursor(57), in: store.keys)
        store.commit(try Ingest.normalize(Data(#"{"data":{"paged":{"id":"1","late":"read","items":"page 57"}}}"#.utf8), plan: plan))
        let record = try #require(store.existing(paged.name + ":1"))
        #expect(record.read(late) == .string("read"))
        #expect(record.read(pages[57]) == .string("page 57"))
        #expect(record.read(pages[56]) == .missing)
    }

    @Test("a rendered key leaves out an argument whose variable is null or not given, as Relay's storage key does, and writes it when the variable has a value")
    func aRenderedKeyLeavesANullArgumentOut() {
        let row = Registry.type("Character")
        let notes = DynamicKey(row, "notes", [KeyArgument("after", [.variable("after")]), KeyArgument("first", [.literal("2")])])
        #expect(notes.render(Variables([:])) == "notes(first:2)", "a variable not given is left out")
        #expect(notes.render(Variables(["after": .null])) == "notes(first:2)", "a variable given null is left out")
        #expect(notes.render(Variables(["after": .string("c2")])) == #"notes(after:"c2",first:2)"#)

        let cursor = DynamicKey(row, "notes", [KeyArgument("after", [.variable("after")])])
        #expect(cursor.render(Variables([:])) == "notes", "a key with no argument left is the bare name")
    }

    @Test("an argument that is an object keeps a null inside it in the rendered key")
    func anObjectArgumentKeepsTheNullsInsideIt() {
        let filter = DynamicKey(Registry.type("Query"), "characters", [KeyArgument("filter", [.literal(#"{"name":"#), .variable("name"), .literal("}")])])
        #expect(filter.render(Variables(["name": .null])) == #"characters(filter:{"name":null})"#)
        #expect(filter.render(Variables([:])) == #"characters(filter:{"name":null})"#, "a variable not given inside an object is null there")
        #expect(filter.render(Variables(["name": .string("Rick")])) == #"characters(filter:{"name":"Rick"})"#)
    }

    @Test("the ingest keys a record by the field the plan names: a selection with no key makes a record keyed by its path, though its type has an id field, and the same selection keyed by id makes Type:id")
    func theIngestKeysARecordByTheFieldThePlanNames() throws {
        // A type and a root field of their own, so that no other test
        // writes the records.
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let keyed = Registry.type("Keyed_" + suffix)
        let query = Registry.type("Query")
        let fieldName = "keyed" + suffix
        func plan(_ key: String?) -> Plan {
            Plan(root: Selection(type: query, key: nil, fields: [
                .linked(fieldName, key: .fixed(Registry.slot(query, fieldName)), plural: false, selection: Selection(type: keyed, key: key, fields: [
                    .scalar("id", key: .fixed(Registry.slot(keyed, "id")), kind: .string, list: false),
                    .scalar("name", key: .fixed(Registry.slot(keyed, "name")), kind: .string, list: false),
                ])),
            ]))
        }
        let response = Data(#"{"data":{"\#(fieldName)":{"id":"1","name":"Rick"}}}"#.utf8)

        let unkeyed = Store()
        unkeyed.commit(try Ingest.normalize(response, plan: plan(nil).resolve(.none, in: unkeyed.keys)))
        let byPath = try #require(unkeyed.existing(Store.rootKey + ":" + fieldName), "the record is keyed by its path")
        #expect(byPath.read(Registry.slot(keyed, "id")) == .string("1"), "the id is a field like any other")
        #expect(unkeyed.existing(keyed.name + ":1") == nil, "no field keys the record but the one the plan names")

        let identified = Store()
        identified.commit(try Ingest.normalize(response, plan: plan("id").resolve(.none, in: identified.keys)))
        let byID = try #require(identified.existing(keyed.name + ":1"), "the record is keyed by its id")
        #expect(byID.read(Registry.slot(keyed, "name")) == .string("Rick"))
        #expect(identified.existing(Store.rootKey + ":" + fieldName) == nil)
    }

    @Test("root fields rendered from variables read back their own values whatever order they arrive in, and a commit of one wakes no body that read another")
    func renderedRootFieldsKeepTheirOwnValues() throws {
        let query = Registry.type("Query")
        let prefix = "spine_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = DynamicKey(query, prefix, [KeyArgument("n", [.variable("n")])])
        func variables(_ number: Int) -> Variables { Variables(["n": .int(number)]) }
        let store = Store()
        // Numbered in this order, written in the reverse one.
        let keys = (0..<10).map { Owner(variables: variables($0), store: store).slot(key) }
        let plan = Plan(root: Selection(type: query, key: nil, fields: [
            .scalar("field", key: .dynamic(key), kind: .string, list: false),
        ]))
        func commit(_ number: Int, _ value: String, into store: Store) throws {
            store.commit(try Ingest.normalize(Data(#"{"data":{"field":"\#(value)"}}"#.utf8), plan: plan.resolve(variables(number), in: store.keys)))
        }
        for number in (0..<10).reversed() { try commit(number, "value \(number)", into: store) }
        #expect(keys.allSatisfy { $0.index < 0 }, "every rendering is numbered apart")
        #expect(store.keys.count(on: query) == 10, "the commits rendered the keys the lenses numbered, and no others")
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
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(operation.variables, in: store.keys)))
        let character = Registry.type("Character")
        // The slot the generated constant holds, and the one the commit
        // rendered, which a rendering of the same text in the store finds.
        let pinned = Registry.slot(character, "notes(first:97)")
        let notes = DynamicKey(character, "notes", [KeyArgument("first", [.variable("count")])])
        let recent = Owner(variables: operation.variables, store: store).slot(notes)
        #expect(pinned.index >= 0, "a constant is a dense slot, with arguments or without")
        #expect(recent.index < 0, "a key rendered from a variable is numbered apart")
        #expect(store.storageKey(of: recent) == "notes(first:98)")

        let data = TestNoteCounts.Data(anchor: Anchor(record: store.root, variables: operation.variables, store: store))
        let rows = try #require(data.characters?.results)
        #expect(rows.map(\.pinned.totalCount) == [3, 0])
        #expect(rows.map(\.recent.totalCount) == [3, 0])
    }

    @Test("a key keeps one slot in a store whichever way it is met first: a rendering of a constant's key reads what the constant wrote, and a constant met after a rendering reads what the rendering wrote")
    func aKeyHasOneSlotWhicheverWayItIsMet() throws {
        let store = Store()
        let written = TestNoteCounts(page: 1, count: 99)
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: store.keys)))

        // The plan met `notes(first:97)` as its constant; a count of 97
        // renders the same key.
        let rendering = TestNoteCounts(page: 1, count: 97)
        let data = TestNoteCounts.Data(anchor: Anchor(record: store.root, variables: rendering.variables, store: store))
        let rick = try #require(data.characters?.results?.first)
        #expect(rick.recent.totalCount == 3, "the rendering reads the constant's slot")

        // The commit rendered `notes(first:99)`; a constant of that text the
        // build names only now, once the store meets it, reads what the
        // rendering wrote. A lens over the store that renders another key
        // is where the store meets it.
        let character = Registry.type("Character")
        let constant = Registry.slot(character, "notes(first:99)")
        #expect(constant.index >= 0, "the build names the text densely")
        _ = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: TestHeaderQuery(id: "1").variables, store: store)).character
        let record = try #require(store.existing("Character:1"))
        #expect(totalCount(record, constant) == 3)
    }

    /// The `totalCount` of the connection a record links to under a slot,
    /// or nil when the slot holds no link.
    func totalCount(_ record: Record, _ slot: Slot) -> Int? {
        guard case .ref(let connection) = record.read(slot) else { return nil }
        guard case .int(let count) = connection.read(Registry.slot(connection.type, "totalCount")) else { return nil }
        return count
    }

    /// The fixture of `TestNoteCounts` with Rick's counts set to `count`.
    func noteCounts(rick count: Int) -> Data {
        let text = String(decoding: fixture("note-counts-1"), as: UTF8.self)
            .replacingOccurrences(of: #""pinned":{"totalCount":3},"recent":{"totalCount":3}"#, with: #""pinned":{"totalCount":\#(count)},"recent":{"totalCount":\#(count)}"#)
        return Data(text.utf8)
    }

    @Test("after a constant adopts a rendering's key, a write through either slot is read through both")
    func aWriteThroughEitherTwinIsReadThroughBoth() throws {
        // A count no other test renders or names, so that the store meets the
        // text as a rendering first.
        let store = Store()
        store.reportMissing = nil
        let written = TestNoteCounts(page: 1, count: 96)
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: store.keys)))
        let rendering = try #require(store.existing("Character:1")).storedSlots.map(\.slot).first { store.storageKey(of: $0) == "notes(first:96)" }
        let rendered = try #require(rendering, "the commit wrote the rendering under the store's number")
        #expect(rendered.index < 0)

        let character = Registry.type("Character")
        let constant = Registry.slot(character, "notes(first:96)")
        // A commit is where the store meets the constant: this one, through
        // the rendering's plan, now resolves to the constant's slot.
        store.commit(try Ingest.normalize(noteCounts(rick: 5), plan: TestNoteCounts.plan.resolve(written.variables, in: store.keys)))
        let record = try #require(store.existing("Character:1"))
        #expect(totalCount(record, constant) == 5, "the constant reads the commit")
        #expect(totalCount(record, rendered) == 5, "the store's number, the constant's twin, reads it too")
        let data = TestNoteCounts.Data(anchor: Anchor(record: store.root, variables: written.variables, store: store))
        #expect(data.characters?.results?.first?.recent.totalCount == 5, "a lens that renders the text reads it")

        // A plan that names the text as its constant writes; the rendering
        // reads it. Its root field is its own, so that no other test meets
        // the key as a constant.
        let query = Registry.type("Query")
        let plan = Plan(root: Selection(type: query, key: nil, fields: [
            .linked("character", key: .fixed(Registry.slot(query, "adopting_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))), plural: false, selection: Selection(type: character, key: "id", fields: [
                .scalar("id", key: .fixed(Registry.slot(character, "id")), kind: .string, list: false),
                .linked("notes", key: .fixed(constant), plural: false, selection: Selection(type: Registry.type("NoteConnection"), key: nil, fields: [
                    .scalar("totalCount", key: .fixed(Registry.slot(Registry.type("NoteConnection"), "totalCount")), kind: .int, list: false),
                ])),
            ])),
        ])).resolve(.none, in: store.keys)
        store.commit(try Ingest.normalize(Data(#"{"data":{"character":{"id":"1","notes":{"totalCount":8}}}}"#.utf8), plan: plan))
        #expect(totalCount(record, rendered) == 8, "the store's number reads what the constant's plan wrote")
        #expect(data.characters?.results?.first?.recent.totalCount == 8)
        let fresh = TestNoteCounts.Data(anchor: Anchor(record: store.root, variables: written.variables, store: store))
        #expect(fresh.characters?.results?.first?.recent.totalCount == 8)
    }

    @Test("a rendering made after the store adopted a constant takes the constant's slot")
    func aRenderingAfterAnAdoptionTakesTheConstantsSlot() throws {
        let store = Store()
        store.reportMissing = nil
        let written = TestNoteCounts(page: 1, count: 95)
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: store.keys)))
        let before = Owner(variables: written.variables, store: store).slot(Slots.Character.notes_041c11)
        #expect(before.index < 0, "the store numbered the text")

        let constant = Registry.slot(Registry.type("Character"), "notes(first:95)")
        // A commit adopts the constant.
        store.commit(try Ingest.normalize(fixture("note-counts-1"), plan: TestNoteCounts.plan.resolve(written.variables, in: store.keys)))
        let after = Owner(variables: written.variables, store: store).slot(Slots.Character.notes_041c11)
        #expect(after.index >= 0)
        #expect(after == constant)
        #expect(totalCount(try #require(store.existing("Character:1")), after) == 3)
    }

    @Test("two stores number the same rendered key apart, each in its own table, and the process numbers nothing for it")
    func twoStoresNumberTheSameRenderingApart() throws {
        let query = Registry.type("Query")
        let header = TestHeaderQuery(id: "9")
        let response = Spec.data("rickandmorty/character-header-9.json")
        let first = Store()
        let second = Store()
        let dense = Registry.slotCount(query)
        for store in [first, second] {
            store.commit(try Ingest.normalize(response, plan: TestHeaderQuery.plan.resolve(header.variables, in: store.keys)))
            let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: header.variables, store: store))
            #expect(data.character?.testHeader.name == "Agency Director")
            #expect(store.keys.count(on: query) == 1, "the store numbered the lookup's key once, for the commit and the read")
        }
        #expect(Registry.slotCount(query) == dense, "the process numbers no key a session rendered")
    }

    @Test("a rendering whose text the build names as a constant takes the constant's slot, so the text has one slot in a store whichever plan writes it")
    func aRenderingOfAConstantTakesItsSlot() throws {
        // A type of its own, so that no other test numbers keys on it.
        let row = Registry.type("Labeled_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let query = Registry.type("Query")
        let link = Registry.slot(query, "labeled" + row.name)
        let id = PlanField.scalar("id", key: .fixed(Registry.slot(row, "id")), kind: .string, list: false)
        let constant = Registry.slot(row, "labels(first:3)")
        let labels = DynamicKey(row, "labels", [KeyArgument("first", [.variable("count")])])
        func plan(_ key: StorageKey) -> Plan {
            Plan(root: Selection(type: query, key: nil, fields: [
                .linked("labeled", key: .fixed(link), plural: false, selection: Selection(type: row, key: "id", fields: [
                    id,
                    .scalar("labels", key: key, kind: .string, list: false),
                ])),
            ]))
        }
        let store = Store()
        let three = Variables(["count": .int(3)])
        let fixed = plan(.fixed(constant)).resolve(.none, in: store.keys)
        let rendered = plan(.dynamic(labels)).resolve(three, in: store.keys)
        guard case .linked(let selection, _, _, _) = rendered.variant(for: query).fields[0].kind else {
            Issue.record("the plan links the row")
            return
        }
        let slot = selection.variant(for: row).fields[1].slot
        #expect(slot.index >= 0, "the rendering took the constant's dense slot")
        #expect(slot == constant)

        store.commit(try Ingest.normalize(Data(#"{"data":{"labeled":{"id":"1","labels":"by the constant"}}}"#.utf8), plan: fixed))
        let record = try #require(store.existing(row.name + ":1"))
        #expect(record.read(Owner(variables: three, store: store).slot(labels)) == .string("by the constant"), "the rendering reads what the constant wrote")
        store.commit(try Ingest.normalize(Data(#"{"data":{"labeled":{"id":"1","labels":"by the rendering"}}}"#.utf8), plan: rendered))
        #expect(record.read(constant) == .string("by the rendering"), "the constant reads what the rendering wrote")
        #expect(record.storedSlots.count == 2, "the id and one value for the text")
        #expect(store.keys.count(on: row) == 0, "the store numbered nothing for a text the build names")
    }

    @Test("a report names a slot the store numbered by its rendered key")
    func aReportNamesAStoreNumberedSlot() throws {
        final class Misses: @unchecked Sendable { var slots: [Slot] = [] }
        let misses = Misses()
        let store = Store()
        store.reportMissing = { _, slot in misses.slots.append(slot) }
        let header = TestHeaderQuery(id: "never-fetched")
        let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: header.variables, store: store))
        #expect(data.character == nil)
        let slot = try #require(misses.slots.first)
        #expect(slot.index < 0, "a key rendered from a variable is the store's")
        #expect(store.storageKey(of: slot) == #"character(id:"never-fetched")"#)
    }

    @Test("a key rendered on a concrete type the plan did not list is numbered by the store where the response is read, and the process numbers only the type's constants")
    func aRenderingOnAnUnlistedTypeIsTheStores() throws {
        // An interface and a concrete type of their own, so that no other
        // test numbers keys on them. The plan lists no concrete type: the
        // response names it.
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let abstract = Registry.type("Tagged_" + suffix)
        let concrete = Registry.type("TaggedThing_" + suffix)
        let query = Registry.type("Query")
        let tag = DynamicKey(abstract, "tag", [KeyArgument("size", [.variable("size")])])
        let plan = Plan(root: Selection(type: query, key: nil, fields: [
            .linked("tagged", key: .fixed(Registry.slot(query, "tagged" + abstract.name)), plural: false, selection: Selection(type: abstract, key: "id", abstract: true, fields: [
                .scalar("id", key: .fixed(Registry.slot(abstract, "id")), kind: .string, list: false),
                .scalar("tag", key: .dynamic(tag), kind: .string, list: false),
            ])),
        ]))
        let size = Variables(["size": .int(2)])
        let store = Store()
        let dense = Registry.slotCount(concrete)
        store.commit(try Ingest.normalize(Data(#"{"data":{"tagged":{"__typename":"\#(concrete.name)","id":"1","tag":"small"}}}"#.utf8), plan: plan.resolve(size, in: store.keys)))
        let record = try #require(store.existing(concrete.name + ":1"))
        #expect(record.type == concrete)
        let slot = Owner(variables: size, store: store).slot(tag, on: concrete)
        #expect(record.read(slot) == .string("small"), "the read finds what the commit wrote")
        #expect(slot.index < 0)
        #expect(store.storageKey(of: slot) == "tag(size:2)")
        #expect(store.keys.count(on: concrete) == 1, "the store numbered the key on the type the response named")
        #expect(Registry.slotCount(concrete) == dense + 1, "the process numbered the type's id, a constant, and not the rendering")
    }

    @Test("a lens read never writes: a root field the store lacks reads nil until the check binds its lookup to the cached entity")
    func lookupBindsInTheCheck() throws {
        final class Misses: @unchecked Sendable {
            var reads: [String] = []
            var slots: [Slot] = []
        }
        let misses = Misses()
        let store = Store()
        store.reportMissing = { [unowned store] record, slot in
            misses.reads.append(record.key + "." + store.storageKey(of: slot))
            misses.slots.append(slot)
        }
        let variables = TestList(page: 1).variables
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(variables, in: store.keys)))

        let detail = TestHeaderQuery(id: "3")
        let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: detail.variables, store: store))
        #expect(data.character == nil, "the read does not resolve the lookup")
        #expect(misses.reads == [#"client:root.character(id:"3")"#])
        let lookup = try #require(misses.slots.first)
        guard case .missing = store.root.read(lookup) else {
            Issue.record("the read wrote the link")
            return
        }
        #expect(store.check(TestHeaderQuery.plan.resolve(detail.variables, in: store.keys)) != .miss)
        #expect(data.character?.testHeader.name == "Summer Smith", "the check wrote the link")
    }

    @Test("an object whose id arrives after a link is keyed by its id, so a detail joins the entity the list fetched")
    func identityArrivesAfterALink() throws {
        final class Misses: @unchecked Sendable { var reads: [String] = [] }
        let misses = Misses()
        let store = Store()
        store.reportMissing = { [unowned store] record, slot in misses.reads.append(record.key + "." + store.storageKey(of: slot)) }
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))

        // The detail's header renders from the store, through the lookup the
        // check binds.
        let header = TestHeaderQuery(id: "9")
        #expect(store.check(TestHeaderQuery.plan.resolve(header.variables, in: store.keys)) != .miss)
        let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: header.variables, store: store))
        #expect(data.character?.testHeader.name == "Agency Director")

        // A second operation on the same root field answers first. Its `id` is
        // the one Relay adds, after the `episode` link, and the server sends
        // it there.
        let episodes = TestEpisodesQuery(id: "9")
        store.commit(try Ingest.normalize(Spec.data("rickandmorty/character-episodes-9.json"), plan: TestEpisodesQuery.plan.resolve(episodes.variables, in: store.keys)))
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
        let changed = store.commit(try Ingest.normalize(Spec.data("rickandmorty/character-header-9.json"), plan: TestHeaderQuery.plan.resolve(header.variables, in: store.keys)))
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
