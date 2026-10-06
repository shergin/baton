import Synchronization

/// The concrete types that satisfy a type condition, an interface or a
/// union, as the build compiled them: what generated code tests a record's
/// type against, and what a lookup without a type probes. A test is an
/// array load by the type's number, and a type the build did not list that
/// a response said is a member is found in the learned table beside it.
@_spi(Generated)
public final class Members: Sendable {
    public let condition: TypeID
    /// The compiled set, for a lookup to probe.
    public let types: [TypeID]
    /// By `TypeID.raw`.
    private let compiled: [Bool]

    public init(_ condition: TypeID, _ types: [TypeID]) {
        self.condition = condition
        self.types = types
        var compiled = [Bool](repeating: false, count: Int(types.map(\.raw).max() ?? -1) + 1)
        for type in types { compiled[Int(type.raw)] = true }
        self.compiled = compiled
        Membership.register(condition, types)
    }

    /// Whether the type satisfies the condition: in the compiled set, or
    /// learned from a response.
    @MainActor public func includes(_ type: TypeID) -> Bool {
        let raw = Int(type.raw)
        if raw < compiled.count, compiled[raw] { return true }
        return Membership.learned(type, of: condition)
    }
}

/// Whether a type is a member of an interface or a union: a table by the
/// condition's number and the type's, filled from the sets the build
/// compiled and from what responses say in Relay's `__isX` fields. A record
/// of a concrete type the build did not list takes its variant from it.
/// Settled once per type.
enum Membership {
    /// The compiled sets, by condition and type, from every `Members` the
    /// generated code made; written at their making, read by the store when
    /// it resolves a variant for a type the plan did not list.
    private static let compiled = Mutex<[[Bool]]>([])
    /// What responses said, by condition and type. The main actor's: the
    /// store learns at a commit, and a lens tests a record's type in a body.
    @MainActor private static var table: [[Bool]] = []

    static func register(_ condition: TypeID, _ types: [TypeID]) {
        compiled.withLock { compiled in
            for type in types { Membership.set(&compiled, condition, type) }
        }
    }

    /// Notes what a response said: records of `type` are members of
    /// `condition`.
    @MainActor static func learn(_ type: TypeID, of condition: TypeID) {
        set(&table, condition, type)
    }

    @MainActor static func learned(_ type: TypeID, of condition: TypeID) -> Bool {
        get(table, condition, type)
    }

    /// Whether the type is a member by the build's set or by a response: for
    /// the variant of a type the plan did not list, off the hot path.
    @MainActor static func includes(_ type: TypeID, _ condition: TypeID) -> Bool {
        compiled.withLock { Membership.get($0, condition, type) } || learned(type, of: condition)
    }

    private static func set(_ table: inout [[Bool]], _ condition: TypeID, _ type: TypeID) {
        let row = Int(condition.raw)
        let column = Int(type.raw)
        if row >= table.count { table.append(contentsOf: repeatElement([], count: row + 1 - table.count)) }
        if column >= table[row].count { table[row].append(contentsOf: repeatElement(false, count: column + 1 - table[row].count)) }
        table[row][column] = true
    }

    private static func get(_ table: [[Bool]], _ condition: TypeID, _ type: TypeID) -> Bool {
        let row = Int(condition.raw)
        let column = Int(type.raw)
        return row < table.count && column < table[row].count && table[row][column]
    }
}
