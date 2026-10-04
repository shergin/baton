import Baton
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

    @Test("a @required link to a record @deleteRecord removed is null: the lens bubbles, a throwing selection collects the error, and a bubbling operation fails")
    func deletedRequiredLink() async throws {
        let transport = RecordedTransport { request in request.operationName == TestRequiredOrigin.name ? fixture("required-origin-1") : nil }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestRequiredOrigin(id: "1"))
        handle.retain()
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
        handle.release()
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
}
