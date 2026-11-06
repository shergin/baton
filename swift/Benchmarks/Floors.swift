import BatonSpec
import Foundation
import Observation

// The platform's own costs, measured beside Baton's rows so that each row
// stands next to what it cannot beat and what it must beat: the tracked
// read of a stored property under Observation, Foundation's parse of the
// fixtures, and the dictionary the store's table is. The engine under
// hydration is measured where the image is, in the persistence section.

/// A row of eight stored properties under the `@Observable` macro, the
/// shape the platform recommends for an item a body reads.
@MainActor
@Observable
final class FloorRow {
    var f0 = 0
    var f1 = 0
    var f2 = 0
    var f3 = 0
    var f4 = 0
    var f5 = 0
    var f6 = 0
    var f7 = 0

    init(_ seed: Int) {
        f0 = seed
        f1 = seed &+ 1
        f2 = seed &+ 2
        f3 = seed &+ 3
        f4 = seed &+ 4
        f5 = seed &+ 5
        f6 = seed &+ 6
        f7 = seed &+ 7
    }
}

/// A value for the dictionary floor: a class, as a record is.
private final class Occupant {}

@MainActor
func floorsBench() throws {
    let rowCount = 20
    let rows = (0..<rowCount).map { FloorRow($0) }
    let reads = rowCount * 8
    measure("floor: an @Observable stored property, untracked, per field", iterations: 50, ops: reads * 20) {
        var sink = 0
        for _ in 0..<20 {
            for row in rows {
                sink &+= row.f0 &+ row.f1 &+ row.f2 &+ row.f3 &+ row.f4 &+ row.f5 &+ row.f6 &+ row.f7
            }
        }
        if sink == 42 { print("") }
    }
    measure("floor: an @Observable stored property, tracked, a body of 8 fields, per field", iterations: 50, ops: reads) {
        var sink = 0
        for row in rows {
            withObservationTracking {
                sink &+= row.f0 &+ row.f1 &+ row.f2 &+ row.f3 &+ row.f4 &+ row.f5 &+ row.f6 &+ row.f7
            } onChange: {}
        }
        if sink == 42 { print("") }
    }

    // Foundation's own parse of the two fixtures: what the oracle's reader
    // pays, and the number the ingest must beat.
    let fixture = Spec.data("rickandmorty/characters-page-1.json")
    let chunk = aniListResponses[0]
    var parsed: Any?
    measure("floor: JSONSerialization over the fixture, Foundation's own parse", iterations: 30, setup: { parsed = nil }) {
        parsed = try! JSONSerialization.jsonObject(with: fixture)
    }
    measure("floor: JSONSerialization over an AniList chunk", iterations: 30, setup: { parsed = nil }) {
        parsed = try! JSONSerialization.jsonObject(with: chunk)
    }
    withExtendedLifetime(parsed) {}

    // The dictionary the store's table is: sixteen-byte keys, heap-held,
    // inserted into a reserved table and found again.
    for size in [899, 6_014] {
        let keys = (0..<size).map { "Character:\(100_000 + $0)" }
        let occupants = (0..<size).map { _ in Occupant() }
        var table: [String: Occupant] = [:]
        measure("floor: [String: AnyObject] insert of \(size) keys, reserved, per key", iterations: 30, ops: size, setup: {
            table = [:]
            table.reserveCapacity(size)
        }) {
            for index in keys.indices { table[keys[index]] = occupants[index] }
        }
        measure("floor: the same table's hit, \(size) keys, per key", iterations: 30, ops: size) {
            var hits = 0
            for key in keys where table[key] != nil { hits &+= 1 }
            if hits == 42 { print("") }
        }
    }
}
