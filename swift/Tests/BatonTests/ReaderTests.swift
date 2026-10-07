@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

@MainActor
@Suite("Honest readers", .timeLimit(.minutes(1)))
struct ReaderTests {
    /// What a store reported while lenses read it.
    final class Reports: @unchecked Sendable {
        var missing: [String] = []
        var unexpected: [String] = []
        var logged: [String] = []
    }

    func store(_ reports: Reports) -> Store {
        let store = Store()
        store.log = { event in
            switch event {
            case .missing(let type, let field): reports.missing.append(type + "." + field)
            case .unexpected(let type, let field): reports.unexpected.append(type + "." + field)
            case .requiredFieldMissing(let type, let path): reports.logged.append(type + " " + path)
            default: break
            }
        }
        return store
    }

    @Test("a field typed non-null that the server sent null reads its zero value and is reported")
    func nullInNonNull() throws {
        let reports = Reports()
        let store = store(reports)
        let query = TestNotesQuery(id: "1")
        store.commit(try Ingest.normalize(fixture("notes-total-null"), plan: TestNotesQuery.plan.resolve(query.variables, in: store.keys)))
        let character = try #require(TestNotesQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).character)
        #expect(character.testNotes.notes.totalCount == 0)
        #expect(reports.unexpected == ["NoteConnection.totalCount"])
        #expect(reports.missing.isEmpty)
    }

    @Test("a non-null link without data reads one placeholder per type and reports the link alone")
    func missingNonNullLink() throws {
        let reports = Reports()
        let store = store(reports)
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let record = try #require(store.existing("Character:1"))
        let character = TestNotes_character(anchor: Anchor(record: record, variables: TestNotesQuery(id: "1").variables, store: store))

        let notes = character.notes
        #expect(notes.totalCount == 0)
        #expect(notes.edges == nil)
        #expect(notes.pageInfo.hasNextPage == false)
        #expect(reports.missing == ["Character.__TestNotes_notes_connection"], "the fields under the placeholder report nothing")
        #expect(reports.unexpected.isEmpty)
        #expect(store.existing(notes.anchor.record.key) == nil, "the placeholder is not a record of the store")

        let again = TestNotes_character(anchor: Anchor(record: record, variables: TestNotesQuery(id: "1").variables, store: store)).notes
        #expect(again.anchor.record === notes.anchor.record, "a second miss of the type reads the same placeholder")
        #expect(again.pageInfo.anchor.record === notes.pageInfo.anchor.record, "a link below a placeholder reads its type's placeholder too")
        #expect(store.existing(notes.pageInfo.anchor.record.key) == nil)
        #expect(reports.missing.count == 2, "each read of the link reports it once, and nothing below it: \(reports.missing)")
    }

    @Test("a @required(action: LOG) field below a placeholder logs nothing, as nothing else under it reports: the link above it reported already")
    func loggedBelowAPlaceholder() throws {
        let reports = Reports()
        let environment = Environment(transport: SilentTransport(), store: store(reports))
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: environment.store.keys)))
        let record = try #require(environment.store.existing("Character:1"))
        let character = TestLoggedNotes_character(anchor: Anchor(record: record, variables: .none, store: environment.store))

        #expect(character.notes.testLogEdges == nil, "the placeholder has no edges, so the required field bubbles")
        #expect(reports.missing == ["Character.notes(first:1)"])
        #expect(reports.logged.isEmpty, "\(reports.logged)")
    }

    @Test("a deferred spread the server could not deliver fails nothing when every field it would have filled is under @catch, however many errors it sent, and the catch reads the first", arguments: ["character-deferred-2-failed", "character-deferred-2-failed-twice"])
    func caughtFailedPart(_ failed: String) async throws {
        let parts = [fixture("caught-part-1"), fixture(failed)]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        let events = LogTests.Events()
        environment.log = events.log
        let query = TestCaughtPartQuery(id: "1")
        try await environment.fetch(query)
        #expect(events.fieldErrors.isEmpty, "a caught error is not logged: \(events.fieldErrors)")

        let handle = environment.handle(for: query)
        let retention = handle.retain()
        await handle.settle()
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        let character = try #require(environment.store.existing("Character:1"))
        let appearances = TestCaughtAppearances_character(anchor: Anchor(record: character, variables: .none, store: environment.store))
        guard case .failure(let caught) = appearances.episode else {
            Issue.record("expected the part's error under @catch, got \(appearances.episode)")
            return
        }
        #expect(caught.errors.map(\.message) == ["appearances unavailable"])
        withExtendedLifetime(retention) {}
    }

    @Test("a deferred spread the server could not deliver, with a field under no @catch, logs each error it sent once, and in a handle or a throwing fetch is the spread's to weigh however many it sent", arguments: [
        ("character-deferred-2-failed", ["appearances unavailable"]),
        ("character-deferred-2-failed-twice", ["appearances unavailable", "episodes timed out"]),
    ])
    func uncaughtFailedPart(_ failed: String, _ sent: [String]) async throws {
        let parts = [fixture("uncaught-part-1"), fixture(failed)]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        let events = LogTests.Events()
        environment.log = events.log
        let query = TestUncaughtPartQuery(id: "1")
        try await environment.fetch(query)
        #expect(events.fieldErrors == sent.map { _ in "character" }, "each error the part sent, once, at the announced path")

        let handle = environment.handle(for: query)
        let retention = handle.retain()
        await handle.settle()
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        let character = try #require(environment.store.existing("Character:1"))
        #expect(character.error(Registry.slot(character.type, "episode"))?.message == "appearances unavailable", "the field keeps the first error")
        withExtendedLifetime(retention) {}
    }

    @Test("a deferred spread the server could not deliver logs each error it sent once, however many fields under no @catch hold the first", arguments: [
        ("character-deferred-2-failed", ["appearances unavailable"]),
        ("character-deferred-2-failed-twice", ["appearances unavailable", "episodes timed out"]),
    ])
    func failedPartOfTwoFields(_ failed: String, _ sent: [String]) async throws {
        let parts = [fixture("two-field-part-1"), fixture(failed)]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        let events = LogTests.Events()
        environment.log = events.log
        try await environment.fetch(TestTwoFieldPartQuery(id: "1"))
        #expect(events.fieldErrors == sent.map { _ in "character" }, "each error the part sent, once, though two fields hold the first")
        let character = try #require(environment.store.existing("Character:1"))
        for field in ["origin", "episode"] {
            #expect(character.error(Registry.slot(character.type, field))?.message == "appearances unavailable", "\(field) holds the first error")
        }
    }

    @Test("a deferred spread the server could not deliver at a record of a type it selects nothing on leaves the error it sent unplaced, and the log hears it once")
    func failedPartWithoutFields() async throws {
        let parts = [fixture("node-deferred-episode-1"), fixture("character-deferred-2-failed")]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        let events = LogTests.Events()
        environment.log = events.log
        try await environment.fetch(TestNodeDeferred(id: "1"))
        #expect(events.fieldErrors == ["character"])
    }

    @Test("a @required link to a record @deleteRecord removed is null: the lens bubbles, a throwing selection collects the error, and a bubbling operation fails")
    func deletedRequiredLink() async throws {
        let transport = RecordedTransport { request in request.operationName == TestRequiredOrigin.name ? fixture("required-origin-1") : nil }
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestRequiredOrigin(id: "1"))
        let retention = handle.retain()
        await until { if case .loading = handle.phase { false } else { true } }
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(data.character.origin.name == "Earth (C-137)")
        let character = try #require(environment.store.existing("Character:1"))
        let throwing = Anchor(record: character, variables: .none, store: environment.store)
        #expect(TestThrowingOrigin_character.fieldErrors(throwing).isEmpty)

        let deletion = TestDeleteNote(id: "L9")
        environment.store.commit(try Ingest.normalize(fixture("delete-location-L9"), plan: TestDeleteNote.plan.resolve(deletion.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(environment.store.existing("Location:L9")?.deleted == true)
        #expect(!TestRequiredOrigin.Data.Character.satisfied(Anchor(record: character, variables: .none, store: environment.store)))
        #expect(TestThrowingOrigin_character.fieldErrors(throwing).map(\.path) == ["origin"])
        guard case .failed(let error) = handle.phase, error is RequiredFieldError else {
            Issue.record("expected the bubbling operation to fail, got \(handle.phase)")
            return
        }
        _ = consume retention
    }

    @Test("a non-null list under @catch that the server sent null reads empty and is reported")
    func caughtNullList() throws {
        let reports = Reports()
        let store = store(reports)
        let query = TestCaughtEpisodes(id: "1")
        store.commit(try Ingest.normalize(fixture("caught-episodes-null"), plan: TestCaughtEpisodes.plan.resolve(query.variables, in: store.keys)))
        let character = try #require(TestCaughtEpisodes.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).character)
        guard case .success(let episodes) = character.caught else {
            Issue.record("the list has no error")
            return
        }
        #expect(episodes.isEmpty)
        #expect(reports.unexpected == ["Character.episode"])
    }

    @Test("a value of another kind than the reader's reads nil and is reported")
    func kindMismatch() throws {
        let reports = Reports()
        let store = store(reports)
        let query = Registry.type("Query")
        let kinds = Registry.type("TestKinds")
        let value = Registry.slot(kinds, "value")
        let plan = Plan(root: Selection(type: query, key: [], fields: [
            .linked("kinds", key: .fixed(Registry.slot(query, "kinds")), plural: false, selection: Selection(type: kinds, key: [], fields: [
                .scalar("value", key: .fixed(value), kind: .string, list: false),
            ])),
        ])).resolve(.none, in: store.keys)
        store.commit(try Ingest.normalize(Data(#"{"data":{"kinds":{"value":"text"}}}"#.utf8), plan: plan))
        let anchor = Anchor(record: try #require(store.existing("client:root:kinds")), variables: .none, store: store)
        #expect(anchor.int(value) == nil)
        #expect(anchor.bool(value) == nil)
        #expect(anchor.requiredDouble(value) == 0)
        #expect(anchor.linked(value) == nil)
        #expect(reports.unexpected.count == 4, "\(reports.unexpected)")
        #expect(anchor.string(value) == "text")
    }

    /// A record whose scalar lists hold values of one kind each, for list
    /// readers of another kind to read: ints, floats, booleans and strings.
    func listKinds(in store: Store) throws -> (anchor: Anchor, ints: Slot, doubles: Slot, bools: Slot, strings: Slot) {
        let query = Registry.type("Query")
        let kinds = Registry.type("TestListKinds")
        let ints = Registry.slot(kinds, "ints")
        let doubles = Registry.slot(kinds, "doubles")
        let bools = Registry.slot(kinds, "bools")
        let strings = Registry.slot(kinds, "strings")
        let plan = Plan(root: Selection(type: query, key: [], fields: [
            .linked("listKinds", key: .fixed(Registry.slot(query, "listKinds")), plural: false, selection: Selection(type: kinds, key: [], fields: [
                .scalar("ints", key: .fixed(ints), kind: .int, list: true),
                .scalar("doubles", key: .fixed(doubles), kind: .double, list: true),
                .scalar("bools", key: .fixed(bools), kind: .bool, list: true),
                .scalar("strings", key: .fixed(strings), kind: .string, list: true),
            ])),
        ])).resolve(.none, in: store.keys)
        let response = #"{"data":{"listKinds":{"ints":[1,2],"doubles":[2.0,2.5,3.0],"bools":[true,false],"strings":["yes","no"]}}}"#
        store.commit(try Ingest.normalize(Data(response.utf8), plan: plan))
        let anchor = Anchor(record: try #require(store.existing("client:root:listKinds")), variables: .none, store: store)
        return (anchor, ints, doubles, bools, strings)
    }

    @Test("a list of floats reads an int element as its double, as the float reader does, and reports nothing")
    func aFloatListReadsAnIntElement() throws {
        let reports = Reports()
        let store = store(reports)
        let lists = try listKinds(in: store)
        #expect(lists.anchor.requiredDoubles(lists.ints) == [1.0, 2.0])
        #expect(lists.anchor.doubles(lists.ints) == [1.0, 2.0])
        #expect(lists.anchor.nullableDoubles(lists.ints) == [1.0, 2.0])
        #expect(reports.unexpected.isEmpty)
    }

    @Test("a list of non-null ints reads a whole float as its int and drops a fractional one, reported once as unexpected")
    func aNonNullIntListReadsAWholeFloatAndDropsAFraction() throws {
        let reports = Reports()
        let store = store(reports)
        let lists = try listKinds(in: store)
        #expect(lists.anchor.requiredInts(lists.doubles) == [2, 3])
        #expect(reports.unexpected == ["TestListKinds.doubles"])
    }

    @Test("a list of nullable ints reads a whole float as its int and a fractional one as nil, reported once as unexpected")
    func aNullableIntListReadsAWholeFloatAndAFractionAsNil() throws {
        let reports = Reports()
        let store = store(reports)
        let lists = try listKinds(in: store)
        #expect(lists.anchor.nullableInts(lists.doubles) == [2, nil, 3])
        #expect(reports.unexpected == ["TestListKinds.doubles"])
    }

    @Test("a list of strings reads a number's or a boolean's text, as the string reader does, and reports nothing")
    func aStringListReadsTheTextOfNumbersAndBooleans() throws {
        let reports = Reports()
        let store = store(reports)
        let lists = try listKinds(in: store)
        #expect(lists.anchor.requiredStrings(lists.ints) == ["1", "2"])
        #expect(lists.anchor.strings(lists.doubles) == ["2.0", "2.5", "3.0"])
        #expect(lists.anchor.nullableStrings(lists.bools) == ["true", "false"])
        #expect(reports.unexpected.isEmpty)
    }

    @Test("a list of booleans drops a string element, or reads it as nil where elements are nullable, and reports it once per read")
    func aBoolListDropsAStringElement() throws {
        let reports = Reports()
        let store = store(reports)
        let lists = try listKinds(in: store)
        #expect(lists.anchor.requiredBools(lists.strings) == [])
        #expect(lists.anchor.nullableBools(lists.strings) == [nil, nil])
        #expect(reports.unexpected == ["TestListKinds.strings", "TestListKinds.strings"])
        #expect(lists.anchor.requiredBools(lists.bools) == [true, false])
    }

    @Test("one owner keeps each key with variables and each spread with arguments apart")
    func ownerKeepsKeysApart() throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        for id in ["1", "2"] {
            #expect(store.check(TestHeaderQuery.plan.resolve(TestHeaderQuery(id: id).variables, in: store.keys)) != .miss, "the lookup binds character(id: \(id))")
        }
        let scopes = TestTwoScopes(a: "1", b: "2")
        let data = TestTwoScopes.Data(anchor: Anchor(record: store.root, variables: scopes.variables, store: store))
        let first = try #require(data.first)
        let second = try #require(data.second)
        #expect(first.name == "Rick Sanchez")
        #expect(second.name == "Morty Smith")
        #expect(first.testNotes.anchor.variables["count"] == .int(1))
        #expect(second.testNotes.anchor.variables["count"] == .int(3))
        #expect(first.testNotes.anchor.owner !== second.testNotes.anchor.owner)
    }

    @Test("a spread's list and input object with a variable inside bind the keys the same arguments written in place wrote")
    func spreadArgumentsHoldingVariables() throws {
        let store = Store()
        store.log = nil
        let keys = TestKeys(id: "7", name: "Rick")
        store.commit(try Ingest.normalize(fixture("keys-1"), plan: TestKeys.plan.resolve(keys.variables, in: store.keys)))
        let query = TestSpreadKeys(id: "7", name: "Rick")
        let data = TestSpreadKeys.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.testKeyArguments.charactersByIds?.map(\.name) == ["Rick Sanchez", "Morty Smith"])
        #expect(data.testKeyArguments.characters?.info?.count == 1)
    }

    @Test("a field error inside a type condition counts for an operation that throws when the record satisfies the condition")
    func errorInsideATypeCondition() throws {
        let store = Store()
        let query = TestThrowingNode(id: "1")
        let changes = try Ingest.normalize(fixture("throwing-node-1"), plan: TestThrowingNode.plan.resolve(query.variables, in: store.keys))
        store.commit(changes)
        let anchor = Anchor(record: store.root, variables: query.variables, store: store)
        #expect(TestThrowingNode.Data.fieldErrors(anchor).map(\.message) == ["name hidden"])
        #expect(changes.uncaughtFieldErrors.map(\.message) == ["name hidden"], "the fetch fails on the same error")
    }

    @Test("fields named like the module's shared enums get lenses of other names, so a spread with arguments inside them still binds")
    func reservedNames() throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        #expect(store.check(TestHeaderQuery.plan.resolve(TestHeaderQuery(id: "1").variables, in: store.keys)) != .miss)
        let query = TestReservedNames(id: "1")
        let data = TestReservedNames.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        let sites: TestReservedNames.Data.SitesLens? = data.sites
        #expect(sites?.testNotes.anchor.variables["count"] == .int(1))
        #expect(data.types?.id == "1")
        #expect(data.slots?.id == "1")
    }

    @Test("fields named like the Swift types, keywords and attribute a lens spells get lenses of other names, and every accessor reads")
    func swiftNames() throws {
        let store = Store()
        store.log = nil
        let query = TestSwiftNames(id: "1")
        store.commit(try Ingest.normalize(fixture("swift-names-1"), plan: TestSwiftNames.plan.resolve(query.variables, in: store.keys)))
        let data = TestSwiftNames.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        let type: TestSwiftNames.Data.TypeLens? = data.type
        let mainActor: TestSwiftNames.Data.MainActorLens? = data.mainActor
        let double: TestSwiftNames.Data.DoubleLens? = data.double
        let owner: TestSwiftNames.Data.Owner? = data.owner
        #expect(type?.id == "1")
        #expect(data.`self`?.id == "1")
        #expect(data.`protocol`?.id == "1")
        #expect(data.`any`?.id == "1")
        #expect(mainActor?.id == "1")
        #expect(data.baton?.id == "1")
        #expect(data.abstractSlots?.id == "1")
        #expect(data.result?.id == "1")
        #expect(data.optional?.id == "1")
        #expect(data.string?.id == "1")
        #expect(data.int?.id == "1")
        #expect(double?.id == "1")
        #expect(data.bool?.id == "1")
        #expect(owner?.id == "1")
        #expect(try data.caught.get()?.id == "1")
        #expect(data.node?.id == "1")
        #expect(data.tokenizer?.ratio == 0.5)
        #expect(data.tokenizer?.count == 2)
        #expect(data.tokenizer?.flag == true)
    }

    @Test("of two fields whose lenses would take one name, the second is checked through its own lens for field errors and required fields")
    func collidingLensNames() throws {
        let store = Store()
        store.log = nil
        let errors = TestCollidingErrors(id: "1")
        store.commit(try Ingest.normalize(fixture("colliding-lenses-name-hidden"), plan: TestCollidingErrors.plan.resolve(errors.variables, in: store.keys)))
        let errorsData = TestCollidingErrors.Data(anchor: Anchor(record: store.root, variables: errors.variables, store: store))
        let second: TestCollidingErrors.Data.TypesLens2? = errorsData.typesLens
        #expect(second?.id == "1")
        #expect(TestCollidingErrors.Data.fieldErrors(errorsData.anchor).map(\.message) == ["name hidden"])
        let required = TestCollidingRequired(id: "1")
        store.commit(try Ingest.normalize(fixture("colliding-lenses-name-hidden"), plan: TestCollidingRequired.plan.resolve(required.variables, in: store.keys)))
        #expect(!TestCollidingRequired.Data.satisfied(Anchor(record: store.root, variables: required.variables, store: store)))
    }

    @Test("a @required field the store never received is reported missing before its lens bubbles")
    func missingRequiredField() throws {
        let reports = Reports()
        let store = store(reports)
        let query = TestNotesQuery(id: "1")
        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(query.variables, in: store.keys)))
        let record = try #require(store.existing("Character:1"))
        let anchor = Anchor(record: record, variables: query.variables, store: store)
        #expect(!TestProfile_character.satisfied(anchor))
        #expect(reports.missing == ["Character.origin"])
    }

    @Test("variables named like Swift's keywords are properties, parameters and request variables of those names")
    func keywordVariables() {
        let query = TestKeywordVariables(where: "1", in: "Rick")
        #expect(query.where == "1")
        #expect(query.variables["where"] == .string("1"))
        #expect(query.variables["in"] == .string("Rick"))
        #expect(query != TestKeywordVariables(where: "2", in: "Rick"))
    }

    @Test("a variable that is a list of input objects is a property, a parameter and a request variable of a list of objects")
    func listOfInputObjects() {
        let rick = FilterCharacter(name: "Rick", status: "Alive")
        let query = TestFilteredCharacters(filters: [rick])
        #expect(query.variables["filters"] == .list([.object(["name": .string("Rick"), "status": .string("Alive")])]))
        #expect(query.variables.json.contains(#""filters":[{"name":"Rick","status":"Alive"}]"#), "\(query.variables.json)")
        #expect(query != TestFilteredCharacters(filters: []))
    }
}
