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
}
