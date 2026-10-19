import AniListDocuments
import Baton
import Observation

/// What the model derives from one entry: a value, so two readings compare.
struct Entry: Equatable {
    let id: Int
    let status: MediaListStatus?
    let progress: Int?
    let title: String?
    let nextEpisodeAt: Int?
}

/// A model that derives one value from every entry of a list fetched in
/// chunks, each chunk an operation value with its handle: the shape of the
/// derived-state recipe's whole operation.
@MainActor
@Observable
final class ListModel {
    /// The entries of every chunk, in order: the derived value.
    private(set) var entries: [Entry] = []
    private var readings: [[Entry]]
    private let handles: [OperationHandle<ListQuery>]
    private let retentions: [Retention]
    private var observations: [Task<Void, Never>] = []

    init(environment: Environment, userId: Int, chunks: Int) {
        handles = (1...chunks).map { environment.handle(for: ListQuery(userId: userId, mediaType: .ANIME, chunk: $0)) }
        retentions = handles.map { $0.retain() }
        // The first reading, untracked and in this turn: a handle the image
        // answered is ready before any stream starts.
        readings = handles.map(Self.read)
        entries = readings.flatMap(\.self)
        // One stream a handle, so a change in one chunk re-reads that chunk.
        for (index, handle) in handles.enumerated() {
            observations.append(Task { [weak self] in
                for await reading in Observations<[Entry], Never>({ Self.read(handle) }) {
                    guard let self else { return }
                    self.apply(reading, at: index)
                }
            })
        }
    }

    /// Applies a chunk's reading only when it differs from the last, so the
    /// streams' first readings, equal to the untracked one, change nothing.
    private func apply(_ reading: [Entry], at index: Int) {
        guard reading != readings[index] else { return }
        readings[index] = reading
        entries = readings.flatMap(\.self)
    }

    /// What the derived value needs of one chunk: five fields an entry, not
    /// the row's whole fragment, since every field read is registered.
    private static func read(_ handle: OperationHandle<ListQuery>) -> [Entry] {
        guard case .ready(let data) = handle.phase else { return [] }
        var entries: [Entry] = []
        for group in data.MediaListCollection?.lists ?? .empty {
            for entry in group.entries ?? .empty {
                let row = entry.entryRow
                let card = row.media?.mediaCard
                entries.append(Entry(id: row.id, status: row.status, progress: row.progress, title: card?.title?.userPreferred, nextEpisodeAt: card?.nextAiringEpisode?.airingAt))
            }
        }
        return entries
    }
}
