import AniListDocuments
import Baton
import BatonInspector
import BatonSpec
import BatonTesting
import Foundation
import Observation
import Testing

/// A response recorded from AniList, by file name under `spec/anilist/`.
func recorded(_ name: String) -> Data {
    Spec.data("anilist/\(name)")
}

/// A transport that answers each chunk of the list with its recording and
/// the save of entry 991 with its shaped response.
func aniListTransport() -> RecordedTransport {
    RecordedTransport { request in
        if request.operationName == SaveEntryMutation.name { return recorded("save-entry-991-progress.json") }
        guard request.operationName == ListQuery.name, case .int(let chunk)? = request.variables["chunk"] else { return nil }
        return chunk <= 2 ? recorded("list-anime-chunk-\(chunk).json") : nil
    }
}

/// The two chunks as the list's screen asks for them: one handle a chunk.
let chunks = [ListQuery(userId: 0, mediaType: .ANIME, chunk: 1), ListQuery(userId: 0, mediaType: .ANIME, chunk: 2)]

/// The entries of one chunk's reading, in the order the response lists them.
@MainActor
func entries(_ data: ListQuery.Data) -> [EntryRow_mediaList] {
    var read: [EntryRow_mediaList] = []
    for group in data.MediaListCollection?.lists ?? .empty {
        for entry in group.entries ?? .empty { read.append(entry.entryRow) }
    }
    return read
}

/// The entries of the recording, from the response's own JSON: what each
/// lens must read.
func recordedEntries(_ chunk: Int) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: recorded("list-anime-chunk-\(chunk).json")) as? [String: Any]
    let collection = (object?["data"] as? [String: Any])?["MediaListCollection"] as? [String: Any]
    let lists = collection?["lists"] as? [[String: Any]] ?? []
    return lists.flatMap { $0["entries"] as? [[String: Any]] ?? [] }
}

@MainActor
@Suite("A list recorded from AniList", .timeLimit(.minutes(1)))
struct AniListTests {
    /// The two chunks, fetched and held as a screen holds them.
    func listScreen(_ environment: Environment) async throws -> ([ListQuery.Data], [Retention]) {
        var readings: [ListQuery.Data] = []
        var retentions: [Retention] = []
        for chunk in chunks {
            let handle = environment.handle(for: chunk)
            retentions.append(handle.retain())
            await handle.settle()
            guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "chunk \(chunk.chunk) did not arrive") }
            readings.append(data)
        }
        return (readings, retentions)
    }

    @Test("two chunks of 500 entries normalize into the records the dump freezes")
    func two_chunks_normalize_into_the_records_the_dump_freezes() async throws {
        let environment = Environment(transport: aniListTransport())
        environment.log = nil
        let (_, retentions) = try await listScreen(environment)

        let url = Spec.directory.appendingPathComponent("anilist/list-anime.store.json")
        let text = StoreExport.text(of: environment.store)
        if ProcessInfo.processInfo.environment["BATON_BLESS"] != nil {
            try Data(text.utf8).write(to: url)
        } else {
            let expected = try String(contentsOf: url, encoding: .utf8)
            let actualLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
            let line = zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            #expect(text == expected, "the store differs from list-anime.store.json at line \((line ?? min(actualLines.count, expectedLines.count)) + 1)")
        }
        withExtendedLifetime(retentions) {}
    }

    @Test("every entry reads through the lenses what the response wrote, its media one record per type and id")
    func every_entry_reads_what_the_response_wrote() async throws {
        let environment = Environment(transport: aniListTransport())
        environment.log = nil
        let (readings, retentions) = try await listScreen(environment)

        for (index, data) in readings.enumerated() {
            let read = entries(data)
            let wrote = try recordedEntries(index + 1)
            #expect(read.count == 500)
            #expect(read.count == wrote.count)
            #expect(data.MediaListCollection?.hasNextChunk == true)
            for (entry, json) in zip(read, wrote) {
                let media = try #require(json["media"] as? [String: Any])
                let title = media["title"] as? [String: Any]
                #expect(entry.id == json["id"] as? Int)
                #expect(entry.status?.scalarText == json["status"] as? String)
                #expect(entry.progress == json["progress"] as? Int)
                #expect(entry.score == json["score"] as? Double)
                #expect(entry.notes == json["notes"] as? String)
                #expect(entry.customLists == nil)
                #expect(entry.updatedAt == json["updatedAt"] as? Int)
                #expect(entry.media?.id == media["id"] as? Int)
                let card = try #require(entry.media?.mediaCard)
                #expect(card.status?.scalarText == media["status"] as? String)
                #expect(card.title?.romaji == title?["romaji"] as? String)
                #expect(card.title?.native == title?["native"] as? String)
                #expect(card.coverImage?.color == (media["coverImage"] as? [String: Any])?["color"] as? String)
                #expect(card.siteUrl == media["siteUrl"] as? String)
                #expect(card.nextAiringEpisode?.airingAt == (media["nextAiringEpisode"] as? [String: Any])?["airingAt"] as? Int)
            }
        }
        // Entry 1 is `MediaList:1`, and the list also holds Cowboy Bebop,
        // `Media:1`: identity is per type, so the two are two records.
        let all = readings.flatMap(entries)
        #expect(all.first?.id == 1)
        #expect(all.contains { $0.media?.id == 1 })
        withExtendedLifetime(retentions) {}
    }

    @Test("an entry asked for by MediaList(id:) is answered by the lookup from the list's records, with no request")
    func an_entry_by_id_is_answered_from_the_list() async throws {
        let transport = aniListTransport()
        let environment = Environment(transport: transport)
        environment.log = nil
        let (_, retentions) = try await listScreen(environment)
        let sent = transport.requestCount

        let handle = environment.handle(for: EntryQuery(id: 991))
        let held = handle.retain()
        guard case .ready(let data) = handle.phase else {
            Issue.record("the lookup did not answer from the store: \(handle.phase)")
            return
        }
        let entry = try #require(data.MediaList?.entryRow)
        #expect(entry.status == .PAUSED)
        #expect(entry.progress == 248)
        #expect(entry.media?.mediaCard.title?.romaji == "ONE PIECE")
        #expect(entry.media?.mediaCard.nextAiringEpisode?.episode == 1181)
        #expect(transport.requestCount == sent)
        withExtendedLifetime((retentions, held)) {}
    }

    @Test("a save that changes one field notifies the list's row and the detail that read it, and no other body")
    func a_save_of_one_field_notifies_the_two_bodies_that_read_it() async throws {
        let environment = Environment(transport: aniListTransport())
        environment.log = nil
        let (readings, retentions) = try await listScreen(environment)
        let handle = environment.handle(for: EntryQuery(id: 991))
        let held = handle.retain()
        guard case .ready(let detail) = handle.phase, let shown = detail.MediaList?.entryRow else {
            Issue.record("the lookup did not answer from the store")
            return
        }

        // Every row's body reads its entry whole, the detail's body reads the
        // entry, and one more body reads entry 991's status alone.
        final class Count: @unchecked Sendable { var fired: [String] = [] }
        let count = Count()
        let rows = readings.flatMap(entries)
        for row in rows {
            let id = row.id
            withObservationTracking { _ = read(row) } onChange: { count.fired.append("row \(id)") }
        }
        withObservationTracking { _ = read(shown) } onChange: { count.fired.append("detail") }
        withObservationTracking { _ = shown.status } onChange: { count.fired.append("status") }

        let saved = try await environment.mutate(SaveEntryMutation(id: 991, progress: 249))
        #expect(saved.SaveMediaListEntry?.entryRow.progress == 249)
        #expect(count.fired.sorted() == ["detail", "row 991"])
        #expect(shown.progress == 249)
        withExtendedLifetime((retentions, held)) {}
    }
}

/// What a row's body reads of an entry: every field of the row's fragment
/// and of its media's card, folded into a number so nothing is skipped.
@MainActor
func read(_ entry: EntryRow_mediaList) -> Int {
    var sink = entry.id
    sink &+= entry.status?.scalarText.utf8.count ?? 0
    sink &+= entry.progress ?? 0
    sink &+= entry.progressVolumes ?? 0
    sink &+= Int(entry.score ?? 0)
    sink &+= entry.repeat ?? 0
    sink &+= entry.priority ?? 0
    sink &+= entry.notes?.utf8.count ?? 0
    sink &+= entry.private == true ? 1 : 0
    sink &+= entry.hiddenFromStatusLists == true ? 1 : 0
    sink &+= entry.customLists?.utf8.count ?? 0
    sink &+= (entry.startedAt?.year ?? 0) &+ (entry.startedAt?.month ?? 0) &+ (entry.startedAt?.day ?? 0)
    sink &+= (entry.completedAt?.year ?? 0) &+ (entry.completedAt?.month ?? 0) &+ (entry.completedAt?.day ?? 0)
    sink &+= entry.updatedAt ?? 0
    guard let media = entry.media else { return sink }
    let card = media.mediaCard
    sink &+= card.id &+ (card.idMal ?? 0)
    sink &+= card.type?.scalarText.utf8.count ?? 0
    sink &+= card.format?.scalarText.utf8.count ?? 0
    sink &+= card.status?.scalarText.utf8.count ?? 0
    sink &+= (card.episodes ?? 0) &+ (card.chapters ?? 0) &+ (card.volumes ?? 0) &+ (card.duration ?? 0)
    sink &+= card.season?.scalarText.utf8.count ?? 0
    sink &+= card.seasonYear ?? 0
    sink &+= card.countryOfOrigin?.utf8.count ?? 0
    sink &+= card.isAdult == true ? 1 : 0
    sink &+= card.siteUrl?.utf8.count ?? 0
    sink &+= card.title?.romaji?.utf8.count ?? 0
    sink &+= card.title?.english?.utf8.count ?? 0
    sink &+= card.title?.native?.utf8.count ?? 0
    sink &+= card.title?.userPreferred?.utf8.count ?? 0
    sink &+= card.coverImage?.large?.utf8.count ?? 0
    sink &+= card.coverImage?.color?.utf8.count ?? 0
    if let airing = card.nextAiringEpisode { sink &+= airing.id &+ airing.episode &+ airing.airingAt }
    return sink
}
