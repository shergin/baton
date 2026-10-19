@_spi(Generated) import Baton
import AniListDocuments
import BatonSpec
import BatonTesting
import Foundation
import Observation

/// The two chunks of the list recorded under `spec/anilist/`, as a screen
/// asks for them: one operation value a chunk.
let aniListChunks = [ListQuery(userId: 0, mediaType: .ANIME, chunk: 1), ListQuery(userId: 0, mediaType: .ANIME, chunk: 2)]

/// The recorded responses, by chunk.
let aniListResponses = [Spec.data("anilist/list-anime-chunk-1.json"), Spec.data("anilist/list-anime-chunk-2.json")]

/// What a row's body reads of an entry: every field of the row's fragment
/// and of its media's card, each slot once, folded into a number so nothing
/// is skipped. `fields` counts the slots read.
@MainActor
func readEntry(_ entry: EntryRow_mediaList, _ fields: inout Int) -> Int {
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
    sink &+= entry.updatedAt ?? 0
    fields &+= 12
    if let started = entry.startedAt { sink &+= (started.year ?? 0) &+ (started.month ?? 0) &+ (started.day ?? 0); fields &+= 3 }
    if let completed = entry.completedAt { sink &+= (completed.year ?? 0) &+ (completed.month ?? 0) &+ (completed.day ?? 0); fields &+= 3 }
    fields &+= 3
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
    fields &+= 14
    if let title = card.title {
        sink &+= (title.romaji?.utf8.count ?? 0) &+ (title.english?.utf8.count ?? 0) &+ (title.native?.utf8.count ?? 0) &+ (title.userPreferred?.utf8.count ?? 0)
        fields &+= 4
    }
    if let cover = card.coverImage { sink &+= (cover.large?.utf8.count ?? 0) &+ (cover.color?.utf8.count ?? 0); fields &+= 2 }
    if let airing = card.nextAiringEpisode { sink &+= airing.id &+ airing.episode &+ airing.airingAt; fields &+= 3 }
    fields &+= 3
    return sink
}

/// The entries of one chunk's reading, in the order the response lists them.
@MainActor
func aniListEntries(_ data: ListQuery.Data) -> [EntryRow_mediaList] {
    var entries: [EntryRow_mediaList] = []
    for group in data.MediaListCollection?.lists ?? .empty {
        for entry in group.entries ?? .empty { entries.append(entry.entryRow) }
    }
    return entries
}

/// A reading over every entry of the chunks' data, the shape a model that
/// derives one value from the whole list runs: what it returns is a number
/// folded from every field.
@MainActor
func readList(_ readings: [ListQuery.Data]) -> Int {
    var fields = 0
    var sink = 0
    for data in readings {
        for entry in aniListEntries(data) { sink &+= readEntry(entry, &fields) }
    }
    return sink
}

/// The fields `readList` reads over `readings`.
@MainActor
func fieldsRead(_ readings: [ListQuery.Data]) -> Int {
    var fields = 0
    for data in readings {
        for entry in aniListEntries(data) { _ = readEntry(entry, &fields) }
    }
    return fields
}

/// A store holding both chunks, committed in order, with a lens over each
/// chunk's root.
@MainActor
func aniListStore(_ persistence: Persistence? = nil) throws -> (Store, [ListQuery.Data]) {
    let store = Store(persistence: persistence)
    var readings: [ListQuery.Data] = []
    for (operation, data) in zip(aniListChunks, aniListResponses) {
        let plan = ListQuery.plan.resolve(operation.variables, in: store.keys)
        store.commit(try Ingest.normalize(data, plan: plan, rootKey: Store.rootKey))
        readings.append(ListQuery.Data(anchor: Anchor(record: store.root, variables: operation.variables, store: store)))
    }
    return (store, readings)
}

@MainActor
func aniListBench() async throws {
    let bytes = aniListResponses.map(\.count)
    print("  responses: \(bytes[0]) and \(bytes[1]) bytes, 500 entries each")

    // The ingest of each chunk, off the clock of any commit.
    let planned = Store()
    let plans = aniListChunks.map { ListQuery.plan.resolve($0.variables, in: planned.keys) }
    measure("ingest of a chunk of 500 entries, bytes -> change set, per chunk", iterations: 30, ops: 2) {
        for (data, plan) in zip(aniListResponses, plans) { _ = try! Ingest.normalize(data, plan: plan, rootKey: Store.rootKey) }
    }
    var fresh = Store()
    var changes: [ChangeSet] = []
    measure("commit of both chunks into an empty store", iterations: 20, setup: {
        fresh = Store()
        changes = zip(aniListChunks, aniListResponses).map { try! Ingest.normalize($1, plan: ListQuery.plan.resolve($0.variables, in: fresh.keys), rootKey: Store.rootKey) }
    }) {
        for change in changes { fresh.commit(change) }
    }
    count("records-anilist-two-chunks", fresh.count, "    records after both chunks: \(fresh.count)")

    // The reading a model that derives one value from the whole list runs,
    // over every field of every entry: untracked, inside one tracking scope,
    // and through `Observations` to its first value. A tracked reading's
    // observers stay on the records until a change ends them, so each
    // tracked sample reads a store of its own.
    let (store, readings) = try aniListStore()
    let fields = fieldsRead(readings)
    print("  a reading of the list: \(fields) fields over 1,000 entries, \(fields / 1_000) an entry")
    measure("the reading, untracked, the whole list", iterations: 50) {
        if readList(readings) == 42 { print("") }
    }
    measure("the reading, untracked, per field", iterations: 50, ops: fields) {
        if readList(readings) == 42 { print("") }
    }
    var tracked = readings
    var trackedStore = store
    measure("the reading inside one tracking scope, the whole list", iterations: 20, setup: { (trackedStore, tracked) = try! aniListStore() }) {
        withObservationTracking { if readList(tracked) == 42 { print("") } } onChange: {}
    }
    measure("the same, per field", iterations: 20, ops: fields, setup: { (trackedStore, tracked) = try! aniListStore() }) {
        withObservationTracking { if readList(tracked) == 42 { print("") } } onChange: {}
    }
    var chunk = [readings[1]]
    measure("one chunk's reading inside its own tracking scope, 500 entries", iterations: 20, setup: { (trackedStore, tracked) = try! aniListStore(); chunk = [tracked[1]] }) {
        withObservationTracking { if readList(chunk) == 42 { print("") } } onChange: {}
    }
    await measureEach("the reading through Observations, made to its first value", iterations: 20) {
        let (_, observed) = try! aniListStore()
        let start = DispatchTime.now().uptimeNanoseconds
        var iterator = Observations<Int, Never> { readList(observed) }.makeAsyncIterator()
        _ = await iterator.next()
        return DispatchTime.now().uptimeNanoseconds - start
    }
    withExtendedLifetime(trackedStore) {}

    // The composition the derived-state recipe gives for a whole operation:
    // one `Observations` a chunk's handle, so a change in one chunk re-reads
    // that chunk, timed from the commit of a one-field save of an entry in
    // the second chunk to that chunk's reading delivered.
    let save = Spec.data("anilist/save-entry-991-progress.json")
    let back = Data(String(decoding: save, as: UTF8.self).replacingOccurrences(of: "\"progress\":249", with: "\"progress\":248").utf8)
    let savePlan = SaveEntryMutation.plan.resolve(SaveEntryMutation(id: 991, progress: 249).variables, in: store.keys)
    let saved = try Ingest.normalize(save, plan: savePlan, rootKey: Store.mutationRootKey)
    let restored = try Ingest.normalize(back, plan: savePlan, rootKey: Store.mutationRootKey)
    var chunkIterator = Observations<Int, Never> { readList([readings[1]]) }.makeAsyncIterator()
    _ = await chunkIterator.next()
    var flip = false
    await measureEach("a one-field save, the commit to its chunk's reading delivered", iterations: 20) {
        flip.toggle()
        let start = DispatchTime.now().uptimeNanoseconds
        store.commit(flip ? saved : restored)
        _ = await chunkIterator.next()
        return DispatchTime.now().uptimeNanoseconds - start
    }

    // The save's commit with every row's body observing its entry whole and
    // a detail's body observing entry 991: the two that read `progress` of
    // that record are told, and no other.
    store.commit(restored)
    let rows = readings.flatMap(aniListEntries)
    let lookup = EntryQuery(id: 991)
    precondition(store.check(EntryQuery.plan.resolve(lookup.variables, in: store.keys)) != .miss, "the lookup did not answer entry 991 from the list")
    let detail = try requireValue(EntryQuery.Data(anchor: Anchor(record: store.root, variables: lookup.variables, store: store)).MediaList?.entryRow)
    let bodies = Observer()
    measure("the save's commit, 1,000 rows and a detail observing", iterations: 20, observer: bodies, setup: {
        store.commit(restored)
        var unused = 0
        bodies.observe(rows + [detail]) { _ = readEntry($0, &unused) }
    }) {
        store.commit(saved)
    }
    count("notifications-anilist-save-one-field", bodies.fired / rounds(20), "    notifications per save: \(bodies.fired / rounds(20)) (the row and the detail that read the entry's progress)")

    // Through the image: the write-behind of both chunks, the file's size
    // after it, and a launch in a new process to the two handles ready.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-bench-anilist-\(UUID().uuidString).sqlite")
    defer {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
    let persistence = Persistence(url: url)
    await persistence.flush()
    await measureEach("write-behind of both chunks, off the main actor", iterations: 10) {
        let (written, _) = try! aniListStore(persistence)
        let start = DispatchTime.now().uptimeNanoseconds
        await persistence.flush()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        withExtendedLifetime(written) {}
        return elapsed
    }
    // Closed, the image has moved its log into the file.
    await persistence.close()
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    print("    the image after both chunks, closed: \(size) bytes")

    func launched(_ flag: String) -> UInt64 {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [flag, url.path]
        child.standardOutput = output
        try! child.run()
        child.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard child.terminationStatus == 0, let elapsed = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fatalError("the launch child failed with status \(child.terminationStatus): \(text)")
        }
        return elapsed
    }
    await measureEach("a launch: open and hydrate at once, both handles ready", iterations: 15) { launched("--anilist-launch") }
    await measureEach("a launch: both handles ready after the image has opened", iterations: 15) { launched("--anilist-launch-opened") }
}

/// What the child process of the AniList launch bench does: from creating
/// the image's handle to both chunks' handles ready from it, or, with
/// `opened`, the handles alone once the file has opened off the main actor.
/// Prints nanoseconds.
@MainActor
func aniListLaunch(_ path: String, opened: Bool) async {
    var start = DispatchTime.now().uptimeNanoseconds
    let persistence = Persistence(url: URL(fileURLWithPath: path))
    if opened {
        await persistence.flush()
        start = DispatchTime.now().uptimeNanoseconds
    }
    let environment = Environment(transport: SilentTransport(), store: Store(persistence: persistence))
    environment.log = nil
    let handles = aniListChunks.map { environment.handle(for: $0) }
    let retentions = handles.map { $0.retain() }
    let ready = handles.allSatisfy { if case .ready = $0.phase { true } else { false } }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(ready && environment.store.hydratedRecords > 6_000, "the image did not answer both chunks")
    print(elapsed)
    withExtendedLifetime(retentions) {}
    await persistence.flush()
}
