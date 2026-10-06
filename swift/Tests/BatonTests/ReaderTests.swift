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
        store.reportMissing = { record, slot in reports.missing.append(record.key + "." + slot.storageKey) }
        store.reportUnexpected = { record, slot, value in reports.unexpected.append(slot.storageKey + " = \(value)") }
        return store
    }

    @Test("a field typed non-null that the server sent null reads its zero value and is reported")
    func nullInNonNull() throws {
        let reports = Reports()
        let store = store(reports)
        let query = TestNotesQuery(id: "1")
        store.commit(try Ingest.normalize(fixture("notes-total-null"), plan: TestNotesQuery.plan.resolve(query.variables)))
        let character = try #require(TestNotesQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).character)
        #expect(character.testNotes.notes.totalCount == 0)
        #expect(reports.unexpected == ["totalCount = null"])
        #expect(reports.missing.isEmpty)
    }

    @Test("a non-null link without data reads one placeholder per type and reports the link alone")
    func missingNonNullLink() throws {
        let reports = Reports()
        let store = store(reports)
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let record = try #require(store.existing("Character:1"))
        let character = TestNotes_character(anchor: Anchor(record: record, variables: TestNotesQuery(id: "1").variables, store: store))

        let notes = character.notes
        #expect(notes.totalCount == 0)
        #expect(notes.edges == nil)
        #expect(notes.pageInfo.hasNextPage == false)
        #expect(reports.missing == ["Character:1.__TestNotes_notes_connection"], "the fields under the placeholder report nothing")
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
        environment.requiredFieldMissing = { record, path in reports.logged.append(record.key + " " + path) }
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let record = try #require(environment.store.existing("Character:1"))
        let character = TestLoggedNotes_character(anchor: Anchor(record: record, variables: .none, store: environment.store))

        #expect(character.notes.testLogEdges == nil, "the placeholder has no edges, so the required field bubbles")
        #expect(reports.missing == ["Character:1.notes(first:1)"])
        #expect(reports.logged.isEmpty, "\(reports.logged)")
    }

    @Test("a deferred spread the server could not deliver fails nothing when every field it would have filled is under @catch, however many errors it sent, and the catch reads the first", arguments: ["character-deferred-2-failed", "character-deferred-2-failed-twice"])
    func caughtFailedPart(_ failed: String) async throws {
        let parts = [fixture("caught-part-1"), fixture(failed)]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        environment.store.reportMissing = nil
        let query = TestCaughtPartQuery(id: "1")
        #expect(try await environment.fetch(TestCaughtPartQuery.self, variables: query.variables).isEmpty)
        try await environment.fetch(query)

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

    @Test("a deferred spread the server could not deliver, with a field under no @catch, reports each error it sent once, and in a handle or a throwing fetch is the spread's to weigh however many it sent", arguments: [
        ("character-deferred-2-failed", ["appearances unavailable"]),
        ("character-deferred-2-failed-twice", ["appearances unavailable", "episodes timed out"]),
    ])
    func uncaughtFailedPart(_ failed: String, _ sent: [String]) async throws {
        let parts = [fixture("uncaught-part-1"), fixture(failed)]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        environment.store.reportMissing = nil
        let query = TestUncaughtPartQuery(id: "1")
        #expect(try await environment.fetch(TestUncaughtPartQuery.self, variables: query.variables).map(\.message) == sent)
        try await environment.fetch(query)

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

    @Test("a deferred spread the server could not deliver reports each error it sent once, however many fields under no @catch hold the first", arguments: [
        ("character-deferred-2-failed", ["appearances unavailable"]),
        ("character-deferred-2-failed-twice", ["appearances unavailable", "episodes timed out"]),
    ])
    func failedPartOfTwoFields(_ failed: String, _ sent: [String]) async throws {
        let parts = [fixture("two-field-part-1"), fixture(failed)]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        environment.store.reportMissing = nil
        let uncaught = try await environment.fetch(TestTwoFieldPartQuery.self, variables: TestTwoFieldPartQuery(id: "1").variables)
        #expect(uncaught.map(\.message) == sent)
        let character = try #require(environment.store.existing("Character:1"))
        for field in ["origin", "episode"] {
            #expect(character.error(Registry.slot(character.type, field))?.message == "appearances unavailable", "\(field) holds the first error")
        }
    }

    @Test("a deferred spread the server could not deliver at a record of a type it selects nothing on leaves every error it sent unplaced")
    func failedPartWithoutFields() async throws {
        let parts = [fixture("node-deferred-episode-1"), fixture("character-deferred-2-failed")]
        let environment = Environment(transport: DeliveryTests.OpenParts(parts))
        environment.store.reportMissing = nil
        let uncaught = try await environment.fetch(TestNodeDeferred.self, variables: TestNodeDeferred(id: "1").variables)
        #expect(uncaught.map(\.message) == ["appearances unavailable"])
    }

    @Test("a @required link to a record @deleteRecord removed is null: the lens bubbles, a throwing selection collects the error, and a bubbling operation fails")
    func deletedRequiredLink() async throws {
        let transport = RecordedTransport { request in request.operationName == TestRequiredOrigin.name ? fixture("required-origin-1") : nil }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
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
        environment.store.commit(try Ingest.normalize(fixture("delete-location-L9"), plan: TestDeleteNote.plan.resolve(deletion.variables), rootKey: Store.mutationRootKey))
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
        store.commit(try Ingest.normalize(fixture("caught-episodes-null"), plan: TestCaughtEpisodes.plan.resolve(query.variables)))
        let character = try #require(TestCaughtEpisodes.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).character)
        guard case .success(let episodes) = character.caught else {
            Issue.record("the list has no error")
            return
        }
        #expect(episodes.isEmpty)
        #expect(reports.unexpected == ["episode = null"])
    }

    @Test("a value of another kind than the reader's reads nil and is reported")
    func kindMismatch() throws {
        let reports = Reports()
        let store = store(reports)
        let query = Registry.type("Query")
        let kinds = Registry.type("TestKinds")
        let value = Registry.slot(kinds, "value")
        let plan = Plan(root: Selection(type: query, hasID: false, fields: [
            .linked("kinds", key: .fixed(Registry.slot(query, "kinds")), plural: false, selection: Selection(type: kinds, hasID: false, fields: [
                .scalar("value", key: .fixed(value), kind: .string, list: false),
            ])),
        ])).resolve(.none)
        store.commit(try Ingest.normalize(Data(#"{"data":{"kinds":{"value":"text"}}}"#.utf8), plan: plan))
        let anchor = Anchor(record: try #require(store.existing("client:root:kinds")), variables: .none, store: store)
        #expect(anchor.int(value) == nil)
        #expect(anchor.bool(value) == nil)
        #expect(anchor.requiredDouble(value) == 0)
        #expect(anchor.linked(value) == nil)
        #expect(reports.unexpected.count == 4, "\(reports.unexpected)")
        #expect(anchor.string(value) == "text")
    }

    @Test("one owner keeps each key with variables and each spread with arguments apart")
    func ownerKeepsKeysApart() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        for id in ["1", "2"] {
            #expect(store.check(TestHeaderQuery.plan.resolve(TestHeaderQuery(id: id).variables)) != .miss, "the lookup binds character(id: \(id))")
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
        store.reportMissing = nil
        let keys = TestKeys(id: "7", name: "Rick")
        store.commit(try Ingest.normalize(fixture("keys-1"), plan: TestKeys.plan.resolve(keys.variables)))
        let query = TestSpreadKeys(id: "7", name: "Rick")
        let data = TestSpreadKeys.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.testKeyArguments.charactersByIds?.map(\.name) == ["Rick Sanchez", "Morty Smith"])
        #expect(data.testKeyArguments.characters?.info?.count == 1)
    }

    @Test("a field error inside a type condition counts for an operation that throws when the record satisfies the condition")
    func errorInsideATypeCondition() throws {
        let store = Store()
        let query = TestThrowingNode(id: "1")
        let changes = try Ingest.normalize(fixture("throwing-node-1"), plan: TestThrowingNode.plan.resolve(query.variables))
        store.commit(changes)
        let anchor = Anchor(record: store.root, variables: query.variables, store: store)
        #expect(TestThrowingNode.Data.fieldErrors(anchor).map(\.message) == ["name hidden"])
        #expect(changes.uncaughtFieldErrors.map(\.message) == ["name hidden"], "the fetch fails on the same error")
    }

    @Test("fields named like the module's shared enums get lenses of other names, so a spread with arguments inside them still binds")
    func reservedNames() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        #expect(store.check(TestHeaderQuery.plan.resolve(TestHeaderQuery(id: "1").variables)) != .miss)
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
        store.reportMissing = nil
        let query = TestSwiftNames(id: "1")
        store.commit(try Ingest.normalize(fixture("swift-names-1"), plan: TestSwiftNames.plan.resolve(query.variables)))
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
        store.reportMissing = nil
        let errors = TestCollidingErrors(id: "1")
        store.commit(try Ingest.normalize(fixture("colliding-lenses-name-hidden"), plan: TestCollidingErrors.plan.resolve(errors.variables)))
        let errorsData = TestCollidingErrors.Data(anchor: Anchor(record: store.root, variables: errors.variables, store: store))
        let second: TestCollidingErrors.Data.TypesLens2? = errorsData.typesLens
        #expect(second?.id == "1")
        #expect(TestCollidingErrors.Data.fieldErrors(errorsData.anchor).map(\.message) == ["name hidden"])
        let required = TestCollidingRequired(id: "1")
        store.commit(try Ingest.normalize(fixture("colliding-lenses-name-hidden"), plan: TestCollidingRequired.plan.resolve(required.variables)))
        #expect(!TestCollidingRequired.Data.satisfied(Anchor(record: store.root, variables: required.variables, store: store)))
    }

    @Test("a @required field the store never received is reported missing before its lens bubbles")
    func missingRequiredField() throws {
        let reports = Reports()
        let store = store(reports)
        let query = TestNotesQuery(id: "1")
        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(query.variables)))
        let record = try #require(store.existing("Character:1"))
        let anchor = Anchor(record: record, variables: query.variables, store: store)
        #expect(!TestProfile_character.satisfied(anchor))
        #expect(reports.missing == ["Character:1.origin"])
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
        let rick: Variable = .object(["name": .string("Rick"), "status": .string("Alive")])
        let query = TestFilteredCharacters(filters: [rick])
        #expect(query.variables["filters"] == .list([rick]))
        #expect(query.variables.json.contains(#""filters":[{"name":"Rick","status":"Alive"}]"#), "\(query.variables.json)")
        #expect(query != TestFilteredCharacters(filters: []))
    }
}
