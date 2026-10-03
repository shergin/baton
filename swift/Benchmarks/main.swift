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
func run() throws {
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
}

try MainActor.assumeIsolated { try run() }
