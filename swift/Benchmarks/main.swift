// The bench suite. Every number in BENCHMARKS.md comes from here.
//
//   swift run -c release BatonBenchmarks
//   swift run -c release BatonBenchmarks --quick   (three samples each, for CI)
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

    @Mutation("""
        mutation BenchDelete($id: ID!) {
          removeNote(id: $id) { removedNoteId @deleteRecord }
        }
        """)
    var delete: BenchDelete.Action

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

    @Query("""
        query BenchNotesSizedQuery($id: ID!, $size: Int) {
          character(id: $id) { ...BenchNotes_character @arguments(count: $size) }
        }
        """)
    var notesSizedQuery: BenchNotesSizedQuery

    @Query("""
        query BenchNodeQuery($id: ID!) {
          node(id: $id) { id }
        }
        """)
    var nodeQuery: BenchNodeQuery

    @Query("""
        query BenchCharacterQuery($id: ID!) {
          character(id: $id) { id name }
        }
        """)
    var characterQuery: BenchCharacterQuery

    @Fragment("""
        fragment BenchCaught_character on Character {
          image @catch
          status @required(action: NONE)
        }
        """)
    var caught: BenchCaught_character
}

/// `--quick`: three samples per measurement, so CI runs every bench once
/// without waiting for numbers worth recording.
let quick = CommandLine.arguments.contains("--quick")

/// How many samples a measurement asked for `iterations` takes.
func rounds(_ iterations: Int) -> Int { quick ? 3 : iterations }

func format(_ nanoseconds: Double) -> String {
    nanoseconds >= 1_000_000 ? String(format: "%8.2f ms", nanoseconds / 1_000_000)
        : nanoseconds >= 1_000 ? String(format: "%8.2f µs", nanoseconds / 1_000)
        : String(format: "%8.1f ns", nanoseconds)
}

func report(_ label: String, _ samples: [Double], ops: Int) {
    let sorted = samples.sorted()
    let best = sorted[0] / Double(ops)
    let median = sorted[sorted.count / 2] / Double(ops)
    print("  \(label.padding(toLength: 64, withPad: " ", startingAt: 0)) best \(format(best))   median \(format(median))")
}

/// Times `body` alone, `iterations` times; `setup` runs before each sample,
/// off the clock. An `observer` counts what its scopes received during the
/// bodies only.
@MainActor
func measure(_ label: String, iterations: Int = 20, ops: Int = 1, observer: Observer? = nil, setup: () -> Void = {}, _ body: () -> Void) {
    var samples: [Double] = []
    for _ in 0..<rounds(iterations) {
        setup()
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        observer?.settle()
    }
    report(label, samples, ops: ops)
}

/// Times an asynchronous step by hand: `body` returns the nanoseconds it
/// wants counted, so setup and teardown stay off the clock.
@MainActor
func measureEach(_ label: String, iterations: Int = 20, ops: Int = 1, _ body: () async -> UInt64) async {
    var samples: [Double] = []
    for _ in 0..<rounds(iterations) { samples.append(Double(await body())) }
    report(label, samples, ops: ops)
}

/// Counts the notifications the observation scopes it starts receive. A
/// scope fires once, and one that a sample did not fire stays armed into the
/// next sample's setup, so each `observe` opens a round of its own and only
/// what a round received before `settle` counts.
@MainActor
final class Observer {
    private final class Round: @unchecked Sendable {
        var fired = 0
    }

    /// What the settled rounds received.
    private(set) var fired = 0
    private var round = Round()

    /// Registers one scope per element, each reading through `read`.
    func observe<Element>(_ elements: [Element], _ read: (Element) -> Void) {
        let round = Round()
        self.round = round
        for element in elements {
            withObservationTracking { read(element) } onChange: { round.fired += 1 }
        }
    }

    /// What the open round has received so far.
    var pending: Int { round.fired }

    /// Counts the current round and closes it.
    func settle() {
        fired += round.fired
        round = Round()
    }
}

@MainActor
func run() async throws {
    let data = Spec.data("rickandmorty/characters-page-1.json")
    let variables = BenchFixture(page: 1).variables
    let plan = BenchFixture.plan.resolve(variables)
    print("Baton benchmarks — fixture \(data.count) bytes, \(ProcessInfo.processInfo.operatingSystemVersionString)\(quick ? ", quick" : "")")

    print("ingest")
    measure("response bytes -> change set", iterations: 30) {
        _ = try! Ingest.normalize(data, plan: plan)
    }
    measure("resolve the fixture plan for a page, per resolution", iterations: 50, ops: 100) {
        for page in 1...100 { _ = BenchFixture.plan.resolve(BenchFixture(page: page).variables) }
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
    let root = BenchFixture.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
    let rows = Array(root.characters!.results!)
    let edited = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
    let editedChanges = try Ingest.normalize(Data(edited.utf8), plan: plan)
    let names = Observer()
    measure("one field changed, 20 rows observing their name", iterations: 20, observer: names, setup: {
        store.commit(changes)
        names.observe(rows) { _ = $0.name }
    }) {
        store.commit(editedChanges)
    }
    print("    notifications per commit: \(names.fired / rounds(20)) (the edited row's name)")
    store.commit(changes)

    print("reads")
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
    try readPathBench(store: store, root: root)

    print("availability")
    measure("check the fixture plan against the store", iterations: 50) {
        _ = store.check(plan)
    }

    print("writes: optimistic layers, one renamed character, 20 rows observing their name")
    let rename = BenchRename(id: "1", name: "Rick Prime")
    let renamePlan = BenchRename.plan.resolve(rename.variables)
    let optimistic = BenchRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable
    let layerChanges = try Ingest.normalize(Data(("{\"data\":" + optimistic.json + "}").utf8), plan: renamePlan, rootKey: Store.mutationRootKey)
    let answer = try Ingest.normalize(Data(#"{"data":{"rename":{"character":{"id":"1","name":"Rick Prime"}}}}"#.utf8), plan: renamePlan, rootKey: Store.mutationRootKey)
    /// Back to the fixture with no layer, every row observing its name.
    func baseline(_ observer: Observer) {
        for layer in store.optimisticLayers { store.revertOptimistic(layer.id) }
        store.commit(changes)
        observer.observe(rows) { _ = $0.name }
    }
    var layer = UUID()
    let applied = Observer()
    measure("apply a layer", iterations: 50, observer: applied, setup: { baseline(applied) }) {
        layer = store.applyOptimistic(layerChanges)
    }
    let reverted = Observer()
    measure("revert it", iterations: 50, observer: reverted, setup: {
        baseline(Observer())
        layer = store.applyOptimistic(layerChanges)
        reverted.observe(rows) { _ = $0.name }
    }) {
        store.revertOptimistic(layer)
    }
    let rebased = Observer()
    measure("commit the fixture under the layer", iterations: 20, observer: rebased, setup: {
        baseline(Observer())
        layer = store.applyOptimistic(layerChanges)
        rebased.observe(rows) { _ = $0.name }
    }) {
        store.commit(changes)
    }
    let resolved = Observer()
    measure("resolve the layer with the server's answer", iterations: 20, observer: resolved, setup: {
        baseline(Observer())
        layer = store.applyOptimistic(layerChanges)
        resolved.observe(rows) { _ = $0.name }
    }) {
        store.commit(answer, replacingOptimistic: layer)
    }
    print("    notifications per step: apply \(applied.fired / rounds(50)), revert \(reverted.fired / rounds(50)), rebase \(rebased.fired / rounds(20)), resolve \(resolved.fired / rounds(20))")
    baseline(Observer())

    let small = Data(#"{"data":{"rename":{"character":{"id":"1","name":"Rick Prime"}}}}"#.utf8)
    print("a mutation's payload: \(small.count) bytes, one record")
    let back = try Ingest.normalize(Data(#"{"data":{"rename":{"character":{"id":"1","name":"Rick Sanchez"}}}}"#.utf8), plan: renamePlan, rootKey: Store.mutationRootKey)
    measure("ingest", iterations: 200) {
        _ = try! Ingest.normalize(small, plan: renamePlan, rootKey: Store.mutationRootKey)
    }
    measure("commit into the 899-record store, one field changing", iterations: 200, setup: { store.commit(back) }) {
        store.commit(answer)
    }
    store.commit(back)
    let frame = Data(#"{"id":"1","type":"next","payload":{"data":{"noteAdded":{"id":"n9"}}}}"#.utf8)
    measure("a subscription frame (\(frame.count) bytes), its envelope read", iterations: 200) {
        _ = try! Ingest.frame(frame)
    }

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
    let landed = Observer()
    measure("commit the errors, 20 rows observing their image", iterations: 20, observer: landed, setup: {
        store.commit(changes)
        landed.observe(rows) { _ = $0.image }
    }) {
        store.commit(erroredChanges)
    }
    let cleared = Observer()
    measure("commit that clears them, 20 rows observing their image", iterations: 20, observer: cleared, setup: {
        store.commit(erroredChanges)
        cleared.observe(rows) { _ = $0.image }
    }) {
        store.commit(changes)
    }
    print("    notifications per commit: errors landing \(landed.fired / rounds(20)), errors clearing \(cleared.fired / rounds(20))")
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

    print("root fields: one reader, other root fields written")
    try rootFieldBench(store: store, root: root)

    print("deletion: one @deleteRecord in a store of about 9,000 records")
    try deletionBench(data: data, plan: plan)

    print("connections: 42 pages of 50 notes merged into one connection")
    try await connectionBench()

    print("lifetime: 42 pages scrolled, release buffer of 10")
    try await scrollBench(data: data)

    print("persistence: the fixture's 898 records and the root, through the image")
    await persistenceBench(changes: changes, edited: editedChanges, plan: plan)

    print("incremental delivery: a multipart response of \(MultipartStub.parts) parts, \(MultipartStub.body.count / 1024) KB")
    try await multipartBench()
}

/// A server that answers every request with one `multipart/mixed` body,
/// handed to the loading system in chunks of 16 KB.
final class MultipartStub: URLProtocol, @unchecked Sendable {
    static let parts = 20
    static let body: Data = {
        let filler = String(repeating: "x", count: 50_000)
        var text = "preamble\r\n"
        for index in 0..<parts {
            text += "---\r\nContent-Type: application/json\r\n\r\n"
            text += #"{"incremental":[{"data":{"text":""# + filler + #""},"path":["a",\#(index)]}],"hasNext":\#(index < parts - 1)}"#
            text += "\r\n"
        }
        return Data((text + "-----\r\n").utf8)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "multipart/mixed; boundary=\"-\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < MultipartStub.body.count {
            let end = min(offset + 16_384, MultipartStub.body.count)
            client?.urlProtocol(self, didLoad: MultipartStub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
func multipartBench() async throws {
    let body = MultipartStub.body
    measure("parse it, in chunks of 16 KB", iterations: 20) {
        var parser = MultipartParser(boundary: "-")
        var count = 0
        var offset = 0
        while offset < body.count {
            let end = min(offset + 16_384, body.count)
            count += parser.push(body[offset..<end]).count
            offset = end
        }
        if count != MultipartStub.parts { print("    parts: \(count)") }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MultipartStub.self]
    let transport = URLSessionTransport(url: URL(string: "https://stub.invalid/graphql")!, session: URLSession(configuration: configuration))
    let request = Request(operationName: "Stub", text: "query Stub { a }", persistedID: "", variables: .none, incremental: true)
    await measureEach("read it through URLSessionTransport, every part", iterations: 10) {
        let start = DispatchTime.now().uptimeNanoseconds
        var count = 0
        do {
            for try await _ in transport.stream(request) { count += 1 }
        } catch {
            print("    failed: \(error)")
        }
        if count != MultipartStub.parts { print("    parts: \(count)") }
        return DispatchTime.now().uptimeNanoseconds - start
    }
}

/// The reads that do not go through a constant slot: a root field whose key
/// has a variable, a field selected on an interface, and a spread with
/// `@arguments`.
@MainActor
func readPathBench(store: Store, root: BenchFixture.Data) throws {
    let count = 1_000
    measure("root field with a variable argument, untracked, per read", iterations: 50, ops: count) {
        var sink = 0
        for _ in 0..<count where root.characters != nil { sink &+= 1 }
        if sink == 42 { print("") }
    }
    measure("the same, tracked, one body per read", iterations: 50, ops: count) {
        var sink = 0
        for _ in 0..<count {
            withObservationTracking { if root.characters != nil { sink &+= 1 } } onChange: {}
        }
        if sink == 42 { print("") }
    }

    let node = BenchNodeQuery(id: "1")
    store.commit(try Ingest.normalize(Data(#"{"data":{"node":{"__typename":"Character","id":"1"}}}"#.utf8), plan: BenchNodeQuery.plan.resolve(node.variables)))
    let character = try requireValue(BenchNodeQuery.Data(anchor: Anchor(record: store.root, variables: node.variables, store: store)).node)
    measure("field selected on an interface, untracked, per read", iterations: 50, ops: count) {
        var sink = 0
        for _ in 0..<count { sink &+= character.id?.utf8.count ?? 0 }
        if sink == 42 { print("") }
    }

    let sized = BenchNotesSizedQuery(id: "1", size: 7)
    // The root link was never fetched and a read does not bind a lookup, so
    // the lens is made over the character the list fetched.
    let owner = BenchNotesSizedQuery.Data.Character(anchor: Anchor(record: try requireValue(store.existing("Character:1")), variables: sized.variables, store: store))
    // The read makes the fragment's lens and compares its scope by identity,
    // so no lookup of a variable is timed with it.
    let bound = owner.benchNotes.anchor.owner
    measure("spread with @arguments, the fragment's lens, per read", iterations: 50, ops: count) {
        var sink = 0
        for _ in 0..<count where owner.benchNotes.anchor.owner === bound { sink &+= 1 }
        if sink == 42 { print("") }
    }
}

struct MissingBenchData: Error {}

func requireValue<Value>(_ value: Value?) throws -> Value {
    guard let value else { throw MissingBenchData() }
    return value
}

/// How often a body that reads one root field wakes while other root fields
/// are written, one commit each. Every one of them is a key of its own on the
/// root record.
@MainActor
func rootFieldBench(store: Store, root: BenchFixture.Data) throws {
    let others = 64
    let commits = try (1...others).map { offset in
        let character = BenchCharacterQuery(id: String(900_000 + offset))
        let payload = #"{"data":{"character":{"id":"\#(900_000 + offset)","name":"Other"}}}"#
        return try Ingest.normalize(Data(payload.utf8), plan: BenchCharacterQuery.plan.resolve(character.variables))
    }
    let reader = Observer()
    reader.observe([root]) { _ = $0.characters }
    for changes in commits {
        store.commit(changes)
        guard reader.pending > 0 else { continue }
        reader.settle()
        reader.observe([root]) { _ = $0.characters }
    }
    reader.settle()
    print("    wakes of a body reading characters(page: 1) while \(others) other root fields are written: \(reader.fired)")
}

/// A commit whose only edit is one `@deleteRecord`, in a store of ten pages
/// of the fixture, about 9,000 records. Each sample deletes another
/// character, one whose id no record of another type has.
@MainActor
func deletionBench(data: Data, plan: ResolvedSelection) throws {
    let store = Store()
    store.reportMissing = nil
    for page in 0..<10 {
        store.commit(try Ingest.normalize(page == 0 ? data : shifted(data, by: page * 100_000), plan: plan))
    }
    let ids = (200..<1_000).map(String.init).filter { id in
        store.existing("Character:" + id) != nil && store.existing("Location:" + id) == nil && store.existing("Episode:" + id) == nil
    }
    let deletions = try ids.map { id in
        try Ingest.normalize(Data(#"{"data":{"removeNote":{"removedNoteId":"\#(id)"}}}"#.utf8), plan: BenchDelete.plan.resolve(BenchDelete(id: id).variables), rootKey: Store.mutationRootKey)
    }
    var next = 0
    measure("commit that deletes one record (\(store.count) records)", iterations: min(20, deletions.count), setup: { next += 1 }) {
        store.commit(deletions[next - 1])
    }
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
    // The rows sit in the write-ahead log until a checkpoint moves them.
    let size = ["", "-wal"].reduce(0) { total, suffix in
        total + (((try? FileManager.default.attributesOfItem(atPath: url.path + suffix))?[.size] as? Int) ?? 0)
    }
    print("    file and its log: \(size) bytes for 898 rows and one root field")

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
        guard child.terminationStatus == 0, let elapsed = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fatalError("the launch child failed with status \(child.terminationStatus): \(text)")
        }
        return elapsed
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
    // Built before any timing: the transport only hands them out.
    let responses = (1...pages).map { notesPage($0, of: pages, size: size) }
    let transport = RecordedTransport { request in
        if request.operationName == BenchNotesQuery.name { return responses[0] }
        guard case .string(let cursor)? = request.variables["cursor"], let number = Int(cursor.dropFirst()) else { return nil }
        return responses[(number + 1) / size]
    }
    // The same pages with no body reading the nodes: what the merge costs
    // as the connection grows, apart from what tracking every node costs.
    do {
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: BenchNotesQuery(id: "1"))
        handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase, let character = data.character?.benchNotes else { return }
        var samples: [Double] = []
        while character.notes.hasNext {
            let start = DispatchTime.now().uptimeNanoseconds
            try await character.notes.loadNext()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        }
        let series = [2, 21, 41].filter { $0 - 2 < samples.count }.map { "page \($0) \(format(samples[$0 - 2]).trimmingCharacters(in: .whitespaces))" }
        report("loadNext with no body reading the nodes, per page of 50", samples, ops: 1)
        print("    by page: \(series.joined(separator: ", "))")
        handle.release()
    }

    let environment = Environment(transport: transport)
    environment.store.reportMissing = nil
    let handle = environment.handle(for: BenchNotesQuery(id: "1"))
    handle.retain()
    await handle.settle()
    guard case .ready(let data) = handle.phase, let character = data.character?.benchNotes else { return }

    let observer = Observer()
    var samples: [Double] = []
    while character.notes.hasNext {
        observer.observe([character]) { _ = $0.notes.nodes }
        let start = DispatchTime.now().uptimeNanoseconds
        try await character.notes.loadNext()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        observer.settle()
    }
    // As the connection grows: the page appended to 1, 20 and 40 pages.
    let series = [2, 21, 41].filter { $0 - 2 < samples.count }.map { "page \($0) \(format(samples[$0 - 2]).trimmingCharacters(in: .whitespaces))" }
    report("loadNext, a body reading every node, per page of 50", samples, ops: 1)
    print("    by page: \(series.joined(separator: ", "))")
    print("    pages appended: \(samples.count), nodes: \(character.notes.nodes.count), notifications: \(observer.fired) (one per page, on the edges slot)")

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

    let refetched = Observer()
    refetched.observe([character]) { _ = $0.notes.nodes }
    try await handle.refetch()
    refetched.settle()
    print("    refetch of the first page: nodes \(character.notes.nodes.count), notifications \(refetched.fired)")
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
