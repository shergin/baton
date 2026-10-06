@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

/// `List.empty`, the value a view substitutes for a nullable plural link it
/// reads as empty, read beside `TestList`'s nullable `characters.results`
/// over `spec/tests/characters-7-8`.
@MainActor
@Suite("Empty lists", .timeLimit(.minutes(1)))
struct EmptyListTests {
    typealias Results = TestList.Data.Characters.Results

    /// The list page as a lens over a store that committed `response`.
    func page(_ response: Data) throws -> TestList.Data.Characters {
        let store = Store()
        let query = TestList(page: 1)
        store.commit(try Ingest.normalize(response, plan: TestList.plan.resolve(query.variables, in: store.keys)))
        let data = TestList.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        return try #require(data.characters)
    }

    @Test("the empty list has no elements, a zero count and equal start and end indices")
    func the_empty_list_has_no_elements() {
        let list = List<Results>.empty
        #expect(list.isEmpty)
        #expect(list.count == 0)
        #expect(list.startIndex == list.endIndex)
        var visited = 0
        for _ in list { visited += 1 }
        #expect(visited == 0)
        #expect(list.map(\.testRow.name).isEmpty)
    }

    @Test("a nullable list the server answered with null reads nil and substitutes the empty list")
    func a_null_list_substitutes_the_empty_list() throws {
        let response = try Oracle.replacing("characters.results", with: .null, in: fixture("characters-7-8"))
        let characters = try page(response)
        #expect(characters.results == nil)
        let results = characters.results ?? .empty
        #expect(results.isEmpty)
        #expect(results.count == 0)
        #expect(results.map(\.testRow.name).isEmpty)
    }

    @Test("a nullable list the server answered with elements reads them in order, and the substitution leaves it as it is")
    func a_present_list_is_unchanged_by_the_substitution() throws {
        let characters = try page(fixture("characters-7-8"))
        let results = try #require(characters.results)
        #expect(results.count == 2)
        #expect(results.map(\.testRow.name) == ["Abradolf Lincler", "Adjudicator Rick"])
        let substituted = characters.results ?? .empty
        #expect(substituted.count == 2)
        #expect(substituted.map(\.testRow.name) == ["Abradolf Lincler", "Adjudicator Rick"])
    }
}
