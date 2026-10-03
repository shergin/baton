// The bench suite. Every number in BENCHMARKS.md comes from here.
//
//   swift run -c release BatonBenchmarks
import Baton
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
    let fixtureURL = URL(fileURLWithPath: "spec/rickandmorty/characters-page-1.json")
    let data = try Data(contentsOf: fixtureURL)
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

    print("lifetime: 42 pages scrolled, release buffer of 10")
    try await scrollBench(data: data)
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

try await run()
