import Baton
import BatonTesting
import Foundation
import Screens
import Shared
import Testing

/// The response a server gave for this operation's selection: the store test
/// of `spec/rickandmorty/character-header-9.json` selects the same fields and
/// one more, `image`, which this operation does not ask for.
func characterNine() throws -> Data {
    let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../../spec/rickandmorty/character-header-9.json")
        .standardized
    return try Data(contentsOf: fixture)
}

/// A target that spreads a fragment of its base reads it through the base's
/// lens: one store, one response, two modules that agree on the slots
/// through the process's registry. Nothing here imports the generated SPI.
@MainActor
@Suite("A fragment spread across modules")
struct SpreadAcrossModulesTests {
    @Test func the_dependents_spread_reads_the_response_through_the_bases_lens_with_the_bound_argument() async throws {
        let transport = RecordedTransport([CharacterScreenQuery.name: try characterNine()])
        let environment = Environment(transport: transport)
        environment.log = nil

        try await environment.fetch(CharacterScreenQuery(id: "9"))
        let handle = environment.handle(for: CharacterScreenQuery(id: "9"), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the fetched data from the store, got \(handle.phase)")
            return
        }
        let row = try #require(data.character?.characterRow)
        #expect(row.name == "Agency Director")
        let status: CharacterStatus_character = row.characterStatus
        #expect(status.status == "Dead")
        #expect(status.species == "Human")
        #expect(
            status.origin?.name == "Earth (Replacement Dimension)",
            "the spread binds `full` to true, so the base's lens reads the field under `@include(if: $full)`"
        )
        #expect(CharacterRow(character: row).status.summary == "Dead, Human, Earth (Replacement Dimension)")
        #expect(transport.requestCount == 1)
    }
}
