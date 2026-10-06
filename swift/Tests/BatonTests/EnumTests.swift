@_spi(Generated) import Baton
import Foundation
import Testing

/// The schema enum `Status`, generated as a Swift enum with a case per value
/// and `unknown` for a value the build does not know, read from
/// `spec/tests/lists-statuses`, whose list carries `GHOST`, which the schema
/// does not declare.
@MainActor
@Suite("Generated enums", .timeLimit(.minutes(1)))
struct EnumTests {
    /// What a store reported as unexpected while lenses read it, by storage
    /// key.
    final class Reports: @unchecked Sendable {
        var unexpected: [String] = []
    }

    @Test("a list of an enum reads each value as its case, a value the schema does not declare as unknown with its text, and a null as nil, reporting nothing")
    func aListOfAnEnumReadsEachValueAsItsCase() throws {
        let store = Store()
        let reports = Reports()
        store.log = { event in if case .unexpected(let type, let field) = event { reports.unexpected.append(type + "." + field) } }
        let mutation = TestSetStatuses()
        store.commit(try Ingest.normalize(fixture("lists-statuses"), plan: TestSetStatuses.plan.resolve(mutation.variables, in: store.keys), rootKey: Store.mutationRootKey))
        let root = try #require(store.existing(Store.mutationRootKey))
        let data = TestSetStatuses.Data(anchor: Anchor(record: root, variables: mutation.variables, store: store))
        #expect(data.setLists?.statuses == [.ALIVE, .unknown("GHOST"), nil, .DEAD])
        #expect(reports.unexpected.isEmpty, "a value the build does not know is data, not a failure")
    }

    @Test("an enum is written as the text it was read from, a value the build does not know included")
    func anEnumIsWrittenAsItsText() {
        #expect(Status(enumText: "GHOST").scalarText == "GHOST")
        #expect(Status(enumText: "GHOST") == .unknown("GHOST"))
        #expect(Status.ALIVE.scalarText == "ALIVE")
        #expect(Status(enumText: "ALIVE") == .ALIVE)
        #expect(Status(enumText: "UNKNOWN") == .UNKNOWN, "the schema's own UNKNOWN is a case, not the unknown case")
    }

    @Test("an enum variable and a list of them are sent as their text")
    func enumVariablesAreSentAsText() {
        let query = TestCharactersWithStatus(status: .DEAD, any: [.ALIVE, .unknown("GHOST")])
        #expect(query.variables.json == #"{"any":["ALIVE","GHOST"],"status":"DEAD"}"#)
        #expect(TestCharactersWithStatus(status: .ALIVE).variables.json == #"{"any":null,"status":"ALIVE"}"#)
    }

    @Test("an optimistic response of a list of an enum renders each case as its text and a nil as null")
    func anOptimisticListOfAnEnumRendersAsText() {
        let optimistic = TestSetStatuses.OptimisticResponse(setLists: .init(statuses: [.ALIVE, nil]))
        #expect(optimistic.variable.json == #"{"setLists":{"statuses":["ALIVE",null]}}"#)
    }
}
