// The bench suite. Every number in BENCHMARKS.md comes from here.
//
//   swift run -c release BatonBenchmarks
import Baton
import BatonSpec
import Foundation
import Observation

@MainActor
struct BenchmarkDocuments {
    @Query("""
        query BenchFixture($page: Int) {
          characters(page: $page) {
            info { count pages next prev }
            results {
              id name status species type gender image created
              origin { id name type dimension created }
              location { id name type dimension created }
              episode {
                id name air_date episode created
                characters { id name image }
              }
            }
          }
        }
        """)
    var fixture: BenchFixture

    @Mutation("""
        mutation BenchRename($id: ID!, $name: String!) {
          rename(id: $id, name: $name) { character { id name } }
        }
        """)
    var rename: BenchRename.Action

    @Fragment("""
        fragment BenchNotes_character on Character
        @refetchable(queryName: "BenchNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 50}, cursor: {type: "String"}) {
          notes(first: $count, after: $cursor) @connection(key: "BenchNotes_notes") {
            totalCount
            edges { node { id text created } }
          }
        }
        """)
    var notes: BenchNotes_character

    @Query("""
        query BenchNotesQuery($id: ID!) {
          character(id: $id) { ...BenchNotes_character }
        }
        """)
    var notesQuery: BenchNotesQuery

    @Fragment("""
        fragment BenchCaught_character on Character {
          image @catch
          status @required(action: NONE)
        }
        """)
    var caught: BenchCaught_character
}

func measure(_ label: String, iterations: Int = 20, ops: Int = 1, _ body: () -> Void) {
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
    }
    samples.sort()
    let best = samples[0] / Double(ops)
    let median = samples[samples.count / 2] / Double(ops)
    let unit: (Double) -> String = { nanoseconds in
        nanoseconds >= 1_000_000 ? String(format: "%8.2f ms", nanoseconds / 1_000_000)
            : nanoseconds >= 1_000 ? String(format: "%8.2f µs", nanoseconds / 1_000)
            : String(format: "%8.1f ns", nanoseconds)
    }
    print("  \(label.padding(toLength: 56, withPad: " ", startingAt: 0)) best \(unit(best))   median \(unit(median))")
}

@MainActor
func run() async throws {
    let data = Spec.data("rickandmorty/characters-page-1.json")
    let variables = BenchFixture(page: 1).variables
    let plan = BenchFixture.plan.resolve(variables)
    print("Baton benchmarks — fixture \(data.count) bytes, \(ProcessInfo.processInfo.operatingSystemVersionString)")

    print("ingest")
    measure("response bytes -> change set", iterations: 30) {
        _ = try! Ingest.normalize(data, plan: plan)
    }

    print("commit")
    let changes = try Ingest.normalize(data, plan: plan)
    measure("into an empty store (899 records)", iterations: 20) {
        Store().commit(changes)
    }
    let store = Store()
    store.commit(changes)
    measure("same payload again (nothing changes)", iterations: 20) {
        store.commit(changes)
    }
    let edited = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
    let editedChanges = try Ingest.normalize(Data(edited.utf8), plan: plan)
    measure("one field changed, 20 rows observed", iterations: 20) {
        store.commit(changes)
        store.commit(editedChanges)
    }

    print("reads")
    let root = BenchFixture.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
    let rows = root.characters!.results!
    let reads = rows.count * 8
    measure("untracked lens read, per field", iterations: 50, ops: reads * 20) {
        var sink = 0
        for _ in 0..<20 {
            for row in rows {
                sink &+= row.name?.utf8.count ?? 0
                sink &+= row.status?.utf8.count ?? 0
                sink &+= row.species?.utf8.count ?? 0
                sink &+= row.type?.utf8.count ?? 0
                sink &+= row.gender?.utf8.count ?? 0
                sink &+= row.image?.utf8.count ?? 0
                sink &+= row.created?.utf8.count ?? 0
                sink &+= row.origin?.name?.utf8.count ?? 0
            }
        }
        if sink == 42 { print("") }
    }
    measure("tracked read, one row body of 8 fields, per field", iterations: 50, ops: reads) {
        var sink = 0
        for row in rows {
            withObservationTracking {
                sink &+= row.name?.utf8.count ?? 0
                sink &+= row.status?.utf8.count ?? 0
                sink &+= row.species?.utf8.count ?? 0
                sink &+= row.type?.utf8.count ?? 0
                sink &+= row.gender?.utf8.count ?? 0
                sink &+= row.image?.utf8.count ?? 0
                sink &+= row.created?.utf8.count ?? 0
                sink &+= row.origin?.name?.utf8.count ?? 0
            } onChange: {}
        }
        if sink == 42 { print("") }
    }

    print("availability")
    measure("check the fixture plan against the store", iterations: 50) {
        _ = store.check(plan)
    }

    print("writes: optimistic layers, one renamed character, 20 rows observed")
    store.commit(changes)  // back to the fixture after the edited commits above
    let rename = BenchRename(id: "1", name: "Rick Prime")
    let renamePlan = BenchRename.plan.resolve(rename.variables)
    let optimistic = BenchRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable
    let layerChanges = try Ingest.normalize(Data(("{\"data\":" + optimistic.json + "}").utf8), plan: renamePlan, rootKey: Store.mutationRootKey)
    let answer = try Ingest.normalize(Data(#"{"data":{"rename":{"character":{"id":"1","name":"Rick Prime"}}}}"#.utf8), plan: renamePlan, rootKey: Store.mutationRootKey)
    final class Counter: @unchecked Sendable { var fired = 0 }
    let counter = Counter()
    func observeRows() {
        for row in rows {
            withObservationTracking { _ = row.name } onChange: { counter.fired += 1 }
        }
    }
    measure("apply a layer and revert it", iterations: 50) {
        observeRows()
        let layer = store.applyOptimistic(layerChanges)
        observeRows()
        store.revertOptimistic(layer)
    }
    print("    notifications per apply-and-revert: \(counter.fired / 50)")
    counter.fired = 0
    // One tracking scope before the apply, one before the restore: the
    // phases in between must not fire anything.
    var phases = [0, 0, 0, 0]
    measure("apply, commit the fixture under it, resolve, restore", iterations: 20) {
        var before = counter.fired
        func account(_ phase: Int) { phases[phase] += counter.fired - before; before = counter.fired }
        observeRows()
        let layer = store.applyOptimistic(layerChanges)
        account(0)
        store.commit(changes)
        account(1)
        store.commit(answer, replacingOptimistic: layer)
        account(2)
        observeRows()
        store.commit(changes)
        account(3)
    }
    print("    notifications per cycle: apply \(phases[0] / 20), rebase under a server commit \(phases[1] / 20), resolve \(phases[2] / 20), restore \(phases[3] / 20)")

    print("errors: the fixture with a field error on every row's image")
    // The same payload, with `errors` naming each of the 20 rows' image.
    let erroredText = String(String(decoding: data, as: UTF8.self).dropLast())
        + ",\"errors\":[" + (0..<20).map { "{\"message\":\"image unavailable\",\"path\":[\"characters\",\"results\",\($0),\"image\"]}" }.joined(separator: ",") + "]}"
    let errored = Data(erroredText.utf8)
    measure("ingest with 20 field errors (plain ingest above)", iterations: 30) {
        _ = try! Ingest.normalize(errored, plan: plan)
    }
    let erroredChanges = try Ingest.normalize(errored, plan: plan)
    print("    errors resolved: \(erroredChanges.fieldErrors.count), uncaught: \(erroredChanges.uncaughtFieldErrors.count)")
    measure("commit the errors, then clear them (two commits, 20 rows observed)", iterations: 20) {
        observeRows()
        store.commit(erroredChanges)
        observeRows()
        store.commit(changes)
    }
    let caughtRows = rows.map { BenchCaught_character(anchor: $0.anchor) }
    measure("@catch read of a field without an error, per field", iterations: 50, ops: caughtRows.count * 20) {
        var sink = 0
        for _ in 0..<20 {
            for row in caughtRows {
                if case .success(let image) = row.image { sink &+= image?.utf8.count ?? 0 }
            }
        }
        if sink == 42 { print("") }
    }
    measure("satisfied check of a lens with one @required field, per lens", iterations: 50, ops: caughtRows.count * 20) {
        var sink = 0
        for _ in 0..<20 {
            for row in caughtRows where BenchCaught_character.satisfied(row.anchor) { sink &+= 1 }
        }
        if sink == 42 { print("") }
    }

    print("connections: 42 pages of 50 notes merged into one connection")
    try await connectionBench()

    print("lifetime: 42 pages scrolled, release buffer of 10")
    try await scrollBench(data: data)

    print("persistence: the fixture's 898 records and the root, through the image")
    await persistenceBench(changes: changes, edited: editedChanges, plan: plan)
}

/// Times an asynchronous step by hand: `body` returns the nanoseconds it
/// wants counted, so setup and teardown stay off the clock.
@MainActor
func measureEach(_ label: String, iterations: Int = 20, ops: Int = 1, _ body: () async -> UInt64) async {
    var samples: [Double] = []
    for _ in 0..<iterations { samples.append(Double(await body())) }
    samples.sort()
    let unit: (Double) -> String = { nanoseconds in
        nanoseconds >= 1_000_000 ? String(format: "%8.2f ms", nanoseconds / 1_000_000)
            : nanoseconds >= 1_000 ? String(format: "%8.2f µs", nanoseconds / 1_000)
            : String(format: "%8.1f ns", nanoseconds)
    }
    print("  \(label.padding(toLength: 56, withPad: " ", startingAt: 0)) best \(unit(samples[0] / Double(ops)))   median \(unit(samples[samples.count / 2] / Double(ops)))")
}

/// The image's costs: what a commit pays on the main actor to hand its
/// records over, what the writer pays off it, and what the availability check
/// pays to read a screen back.
@MainActor
func persistenceBench(changes: ChangeSet, edited: ChangeSet, plan: ResolvedSelection) async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("baton-bench-\(UUID().uuidString).sqlite")
    defer {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
    func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // The process has not touched SQLite yet: this is what a launch pays once.
    let start = now()
    let persistence = Persistence(url: url)
    let missed = Store(persistence: persistence).check(plan)
    print("  first use in the process (open, create, a read that misses): \(String(format: "%.2f", Double(now() - start) / 1_000_000)) ms\(missed ? " (unexpected hit)" : "")")

    measure("commit into an empty store, image on (899 records)", iterations: 20) {
        Store(persistence: persistence).commit(changes)
    }
    await persistence.flush()

    await measureEach("write-behind of that commit, off the main actor") {
        let store = Store(persistence: persistence)
        store.commit(changes)
        let start = now()
        await persistence.flush()
        return now() - start
    }
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    print("    file: \(size) bytes for 898 rows and one root field")

    let persisted = Store(persistence: persistence)
    persisted.commit(changes)
    await persistence.flush()
    await measureEach("write-behind of one changed record") {
        persisted.commit(edited)
        let start = now()
        await persistence.flush()
        let elapsed = now() - start
        persisted.commit(changes)
        await persistence.flush()
        return elapsed
    }

    measure("hydration: the check reads 898 rows into an empty store", iterations: 20) {
        precondition(Store(persistence: persistence).check(plan))
    }
    measure("the same, per record", iterations: 20, ops: 898) {
        precondition(Store(persistence: persistence).check(plan))
    }
    let hydrated = Store(persistence: persistence)
    precondition(hydrated.check(plan))
    measure("the check once the records are in memory", iterations: 50) {
        precondition(hydrated.check(plan))
    }

    await measureEach("hydration right behind a commit of 899 records") {
        Store(persistence: persistence).commit(changes)
        let store = Store(persistence: persistence)
        let start = now()
        precondition(store.check(plan))
        let elapsed = now() - start
        await persistence.flush()
        return elapsed
    }

    // A launch: this program again, as a process that has never touched
    // SQLite, answering the fixture from the image. Once asking the moment
    // the image's handle exists, so the main actor pays for the open too;
    // once asking after the open has finished off it, as an app does that
    // makes its environment before its first view.
    func launched(_ flag: String) -> UInt64 {
        let child = Process()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [flag, url.path]
        child.standardOutput = output
        try! child.run()
        child.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    await measureEach("a launch: open and hydrate at once, in a new process", iterations: 15) { launched("--launch") }
    await measureEach("a launch: hydrate after the image has opened", iterations: 15) { launched("--launch-opened") }
}

/// What the child process of the launch bench does: from creating the image's
/// handle to the availability check answering from it, or, with `opened`,
/// the check alone once the file has opened off the main actor. Prints
/// nanoseconds.
@MainActor
func launch(_ path: String, opened: Bool) async {
    let plan = BenchFixture.plan.resolve(BenchFixture(page: 1).variables)
    var start = DispatchTime.now().uptimeNanoseconds
    let persistence = Persistence(url: URL(fileURLWithPath: path))
    let store = Store(persistence: persistence)
    if opened {
        await persistence.flush()
        start = DispatchTime.now().uptimeNanoseconds
    }
    let complete = store.check(plan)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    precondition(complete && store.hydratedRecords == 898)
    print(elapsed)
    // The rows it read carry this launch's generation once this is written,
    // so the next launch finds them.
    await persistence.flush()
}

/// A synthetic page of the notes connection: the first as the screen's query
/// delivers it, the rest as the pagination query does.
func notesPage(_ page: Int, of pages: Int, size: Int) -> Data {
    let start = (page - 1) * size
    let edges = (0..<size).map { offset in
        let number = start + offset
        return "{\"cursor\":\"c\(number)\",\"node\":{\"__typename\":\"Note\",\"id\":\"n\(number)\",\"text\":\"Note \(number)\",\"created\":\"2026-10-03\"}}"
    }.joined(separator: ",")
    let notes = "{\"totalCount\":\(pages * size),\"edges\":[\(edges)],\"pageInfo\":{\"endCursor\":\"c\(start + size - 1)\",\"hasNextPage\":\(page < pages)}}"
    let body = page == 1
        ? "{\"character\":{\"id\":\"1\",\"notes\":\(notes)}}"
        : "{\"node\":{\"__typename\":\"Character\",\"id\":\"1\",\"notes\":\(notes)}}"
    return Data("{\"data\":\(body)}".utf8)
}

@MainActor
func connectionBench() async throws {
    let pages = 42
    let size = 50
    let transport = RecordedTransport { request in
        if request.operationName == BenchNotesQuery.name { return notesPage(1, of: pages, size: size) }
        guard case .string(let cursor)? = request.variables["cursor"], let number = Int(cursor.dropFirst()) else { return nil }
        return notesPage((number + 1) / size + 1, of: pages, size: size)
    }
    let environment = Environment(transport: transport)
    environment.store.reportMissing = nil
    let handle = environment.handle(for: BenchNotesQuery(id: "1"))
    handle.retain()
    await handle.settle()
    guard case .ready(let data) = handle.phase, let character = data.character?.benchNotes else { return }

    final class Counter: @unchecked Sendable { var fired = 0 }
    let counter = Counter()
    func observe() {
        withObservationTracking { _ = character.notes.nodes } onChange: { counter.fired += 1 }
    }
    var samples: [Double] = []
    while character.notes.hasNext {
        observe()
        let start = DispatchTime.now().uptimeNanoseconds
        try await character.notes.loadNext()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
    }
    samples.sort()
    print("  loadNext (transport, ingest, merge), per page of 50           best \(String(format: "%8.2f µs", samples[0]))   median \(String(format: "%8.2f µs", samples[samples.count / 2]))")
    print("    pages appended: \(samples.count), nodes: \(character.notes.nodes.count), notifications: \(counter.fired) (one per page, on the edges slot)")

    let nodes = character.notes.nodes.count
    measure("nodes of the merged connection (\(nodes) lenses), untracked", iterations: 30) {
        _ = character.notes.nodes
    }
    measure("nodes of the merged connection, tracked", iterations: 30) {
        withObservationTracking { _ = character.notes.nodes } onChange: {}
    }

    let before = environment.store.count
    environment.collect()
    print("    records before collection \(before), after \(environment.store.count) (the pages' own records go; the connection keeps the edges and nodes)")

    counter.fired = 0
    observe()
    await handle.refetch()
    print("    refetch of the first page: nodes \(character.notes.nodes.count), notifications \(counter.fired)")
}

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// A page of the fixture with every id shifted, so each page is distinct data.
func shifted(_ data: Data, by offset: Int) -> Data {
    let text = String(decoding: data, as: UTF8.self)
    let regex = try! NSRegularExpression(pattern: "\"id\":\"(\\d+)\"")
    let mutable = NSMutableString(string: text)
    var location = 0
    while let match = regex.firstMatch(in: mutable as String, range: NSRange(location: location, length: mutable.length - location)) {
        let id = Int(mutable.substring(with: match.range(at: 1)))!
        let replacement = "\"id\":\"\(id + offset)\""
        mutable.replaceCharacters(in: match.range, with: replacement)
        location = match.range.location + replacement.utf16.count
    }
    return Data((mutable as String).utf8)
}

@MainActor
func scrollBench(data: Data) async throws {
    let pages: [Data] = (1...42).map { page in page == 1 ? data : shifted(data, by: page * 100_000) }
    let transport = RecordedTransport { request in
        guard case .int(let page)? = request.variables["page"] else { return nil }
        return pages[page - 1]
    }
    let environment = Environment(transport: transport)
    environment.releaseBufferSize = 10
    var baseline = 0
    var report: [String] = []
    var collectionCost: [Double] = []
    for page in 1...42 {
        let handle = environment.handle(for: BenchFixture(page: page))
        handle.retain()
        await handle.settle()
        handle.release()
        let start = DispatchTime.now().uptimeNanoseconds
        environment.collect()
        collectionCost.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        if page == 1 { baseline = footprint() }
        if [1, 5, 10, 11, 20, 30, 42].contains(page) {
            let delta = Double(footprint() - baseline) / 1_048_576
            report.append("  page \(String(page).padding(toLength: 2, withPad: " ", startingAt: 0)): \(String(environment.store.count).padding(toLength: 6, withPad: " ", startingAt: 0)) records, \(String(environment.rootCount).padding(toLength: 2, withPad: " ", startingAt: 0)) roots, footprint \(delta >= 0 ? "+" : "")\(String(format: "%.1f", delta)) MB since page 1")
        }
    }
    report.forEach { print($0) }
    collectionCost.sort()
    print("  collection pass: best \(String(format: "%.2f", collectionCost[0])) ms, median \(String(format: "%.2f", collectionCost[collectionCost.count / 2])) ms, worst \(String(format: "%.2f", collectionCost.last!)) ms")
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--launch") {
    await launch(CommandLine.arguments[2], opened: CommandLine.arguments[1] == "--launch-opened")
} else {
    try await run()
}
