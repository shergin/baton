import AniListDocuments
import Baton
import BatonTesting
import Foundation
import Observation
import Testing

/// The model of the derived-state recipe's whole operation, over the list
/// recorded under `spec/anilist/`.
@MainActor
@Suite("A model deriving from a whole list", .timeLimit(.minutes(1)))
struct ListModelTests {
    /// How long a test waits for a change it expects not to come.
    let quiet = Duration.milliseconds(300)

    /// An environment whose store holds both chunks, held as a screen holds them.
    func filled() async throws -> (Environment, RecordedTransport, [Retention]) {
        let transport = aniListTransport()
        let environment = Environment(transport: transport)
        environment.log = nil
        var retentions: [Retention] = []
        for chunk in chunks {
            let handle = environment.handle(for: chunk)
            retentions.append(handle.retain())
            await handle.settle()
        }
        return (environment, transport, retentions)
    }

    @Test("a model made over a store that holds every chunk has every entry in the turn it is made, with no request")
    func a_model_has_every_entry_in_the_turn_it_is_made() async throws {
        let (environment, transport, retentions) = try await filled()
        let sent = transport.requestCount

        let model = ListModel(environment: environment, userId: 0, chunks: 2)
        #expect(model.entries.count == 1_000)
        #expect(model.entries.first == Entry(id: 1, status: .COMPLETED, progress: 12, title: "009-1", nextEpisodeAt: nil))
        #expect(model.entries.first { $0.id == 991 } == Entry(id: 991, status: .PAUSED, progress: 248, title: "ONE PIECE", nextEpisodeAt: 1_798_985_760))
        #expect(transport.requestCount == sent)
        withExtendedLifetime(retentions) {}
    }

    @Test("the streams' first readings change nothing, and a save in one chunk changes the one entry it saved")
    func a_save_changes_the_one_entry_and_the_first_readings_nothing() async throws {
        let (environment, _, retentions) = try await filled()
        let model = ListModel(environment: environment, userId: 0, chunks: 2)
        let before = model.entries

        final class Count: @unchecked Sendable { var changes = 0 }
        let count = Count()
        withObservationTracking { _ = model.entries } onChange: { count.changes += 1 }
        try await Task.sleep(for: quiet)
        #expect(count.changes == 0, "a stream's first reading is equal to the untracked one")

        _ = try await environment.mutate(SaveEntryMutation(id: 991, progress: 249))
        #expect(await wait(until: { model.entries.first { $0.id == 991 }?.progress == 249 }))
        #expect(count.changes == 1)
        let changed = zip(before, model.entries).filter { $0 != $1 }.map(\.0.id)
        #expect(changed == [991])
        withExtendedLifetime(retentions) {}
    }
}
