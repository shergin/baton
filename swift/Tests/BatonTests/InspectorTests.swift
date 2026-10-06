@_spi(Generated) import Baton
import BatonInspector
import BatonSpec
import BatonTesting
import Foundation
import Testing

@MainActor
@Suite("The store export", .timeLimit(.minutes(1)))
struct InspectorTests {
    @Test("a store filled by a committed payload exports the dump spec/ freezes for that response")
    func aCommittedPayloadExportsItsDump() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        try await environment.commitPayload(Fixture(page: 1), fixtureData)
        let expected = try String(contentsOf: Spec.directory.appendingPathComponent("rickandmorty/characters-page-1.store.json"), encoding: .utf8)
        #expect(StoreExport.text(of: environment.store) == expected)
    }

    @Test("a new store exports its three roots and nothing else")
    func anEmptyStoreExportsItsRoots() {
        let store = Store()
        #expect(StoreExport.text(of: store) == Self.emptyExport)
    }

    @Test("a record @deleteRecord deleted exports as null")
    func aDeletedRecordExportsAsNull() throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("characters-7-8"), plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let removal = TestRemoveNote(id: "7", connections: [])
        store.commit(try Ingest.normalize(fixture("remove-note-7"), plan: TestRemoveNote.plan.resolve(removal.variables, in: store.keys), rootKey: Store.mutationRootKey))
        let lines = StoreExport.text(of: store).split(separator: "\n").map(String.init)
        #expect(lines.contains("  \"Character:7\": null,"))
        #expect(lines.contains { $0.hasPrefix("  \"Character:8\": {\"__typename\": \"Character\"") }, "the record beside it keeps its fields")
    }

    @Test("the export sorts its records by key and each record's fields by storage key")
    func theExportSortsRecordsAndFields() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        try await environment.commitPayload(Fixture(page: 1), fixtureData)
        let text = StoreExport.text(of: environment.store)
        let lines = text.split(separator: "\n").dropFirst().dropLast().map(String.init)
        let keys = try lines.map { try #require(Self.key(of: $0)) }
        #expect(keys.count > 1)
        #expect(keys == keys.sorted())
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set(keys), "the export is JSON with one member per line")
        for line in lines {
            guard let fields = Self.fields(of: line) else { continue }
            #expect(fields == fields.sorted(), "\(line)")
        }
    }

    /// The text of a new store: the three roots every store holds, with
    /// nothing under them.
    static let emptyExport = """
        {
          "client:root": {"__typename": "Query"},
          "client:root:mutation": {"__typename": "Mutation"},
          "client:root:subscription": {"__typename": "Subscription"}
        }

        """

    /// The record key a line of the export begins with.
    static func key(of line: String) -> String? {
        guard line.hasPrefix("  \""), let end = line.range(of: "\": ") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound])
    }

    /// The top-level field names of a record line, in the order written.
    static func fields(of line: String) -> [String]? {
        guard let start = line.range(of: "\": {") else { return nil }
        var body = line[start.upperBound...]
        if body.hasSuffix(",") { body = body.dropLast() }
        var names: [String] = []
        var depth = 0
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "\"" {
                let close = Self.closingQuote(in: body, after: index)
                let after = body.index(after: close)
                if depth == 0, after < body.endIndex, body[after] == ":" {
                    names.append(String(body[body.index(after: index)..<close]))
                }
                index = after
                continue
            }
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
            index = body.index(after: index)
        }
        return names
    }

    /// The index of the quote that closes the string opening at `opening`.
    static func closingQuote(in text: Substring, after opening: Substring.Index) -> Substring.Index {
        var index = text.index(after: opening)
        while text[index] != "\"" {
            if text[index] == "\\" { index = text.index(after: index) }
            index = text.index(after: index)
        }
        return index
    }
}
