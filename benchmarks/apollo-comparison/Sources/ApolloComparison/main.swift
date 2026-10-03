// Apollo iOS 2.4 on the same fixture and operation, for BENCHMARKS.md.
//
//   swift run -c release ApolloComparison
//
// Fairness notes: the response was recorded for Apollo's own query text, which
// adds `__typename` to every object (849 KB against Baton's 686 KB), because
// Apollo's normalizer keys on it; the schema configuration keys entities by
// `id`, as Baton does; the parse step includes JSONSerialization, as Apollo's
// own interceptor does.
import Apollo
@_spi(Unsafe) import ApolloAPI
import Foundation
import RickAndMortyAPI

func measure(_ label: String, iterations: Int = 20, ops: Int = 1, _ body: () async throws -> Void) async throws {
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
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

let data = try Data(contentsOf: URL(fileURLWithPath: "fixture-apollo.json"))
let query = FixtureQuery(page: .some(1))
let httpResponse = HTTPURLResponse(url: URL(string: "https://rickandmortyapi.com/graphql")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
let parser = JSONResponseParser(response: httpResponse, operationVariables: query.__variables, includeCacheRecords: true)

print("Apollo iOS 2.4.0 — fixture \(data.count) bytes, \(ProcessInfo.processInfo.operatingSystemVersionString)")

print("parse")
try await measure("JSONSerialization only", iterations: 30) {
    _ = try JSONSerialization.jsonObject(with: data)
}
try await measure("JSONResponseParser: bytes -> models + records", iterations: 30) {
    _ = try await parser.parse(dataChunk: data, mergingIncrementalItemsInto: nil) as ParsedResult<FixtureQuery>?
}

let parsed = try await parser.parse(dataChunk: data, mergingIncrementalItemsInto: nil) as ParsedResult<FixtureQuery>?
guard let parsed, let records = parsed.cacheRecords else {
    print("no records produced"); exit(1)
}
print("  records produced: \(records.storage.count)")

print("publish")
try await measure("into an empty store (InMemoryNormalizedCache)", iterations: 20) {
    let store = ApolloStore(cache: InMemoryNormalizedCache())
    try await store.publish(records: records)
}
let store = ApolloStore(cache: InMemoryNormalizedCache())
try await store.publish(records: records)
try await measure("same records again (nothing changes)", iterations: 20) {
    try await store.publish(records: records)
}

print("read")
try await measure("store.load(query): cache -> models (whole query)", iterations: 20) {
    _ = try await store.load(query)
}
let loaded = try await store.load(query)
let rows = loaded?.data?.characters?.results?.compactMap { $0 } ?? []
print("  rows read back: \(rows.count)")
try await measure("model field read, per field (DataDict access)", iterations: 50, ops: rows.count * 8 * 20) {
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
