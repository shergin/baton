import Synchronization

/// An interned schema type.
@_spi(Generated)
public struct TypeID: Hashable, Sendable {
    /// The number the process gave the type.
    @_spi(Generated) public let raw: Int32

    /// The type's name, for keys and diagnostics.
    public var name: String { Registry.typeName(self) }
}

/// An interned storage key of one type: where a record stores the field's
/// value. A key the compiler emitted as a constant, with arguments or
/// without, has a dense index, from zero, into the values a record of the
/// type makes room for; a program holds a bounded number of constants. A
/// key rendered from variables, of which a session makes one per cursor
/// and per id, has a negative index, numbered apart by the store that
/// renders it (`Keys`), and a record keeps it in a short list of the keys
/// written to it, so the keys a session makes never widen the records of
/// their type. Generated code holds slots as `static let`s; an app meets
/// one only in the store's reports, and the store names it by its key.
@_spi(Generated)
public struct Slot: Hashable, Sendable {
    @_spi(Generated) public let type: TypeID
    @_spi(Generated) public let index: Int32
}

/// A storage key read on whatever concrete type a record has: a field
/// selected on an interface or union. The slot of each type is resolved on
/// its first read there, so every later read is two array loads.
@_spi(Generated)
@MainActor
public final class AbstractSlot {
    nonisolated public let storageKey: String
    /// The scope's hold on the store's keys when the key was rendered from
    /// variables, which number it on a type that has not met it; nil for
    /// the build's key.
    nonisolated let hold: Keys.Hold?
    /// Slot index by `TypeID.raw`; `Int32.min` until the type is first read.
    private var indices: ContiguousArray<Int32> = []

    nonisolated public convenience init(_ storageKey: String) {
        self.init(storageKey, hold: nil)
    }

    nonisolated init(_ storageKey: String, hold: Keys.Hold?) {
        self.storageKey = storageKey
        self.hold = hold
    }

    /// The key's slot on `type`.
    @inline(__always)
    public func on(_ type: TypeID) -> Slot {
        let position = Int(type.raw)
        if position < indices.count, indices[position] != .min {
            return Slot(type: type, index: indices[position])
        }
        return resolve(type)
    }

    private func resolve(_ type: TypeID) -> Slot {
        let slot = hold.map { $0.keys.slot(type, storageKey, for: $0) } ?? Registry.slot(type, storageKey)
        let position = Int(type.raw)
        if position >= indices.count {
            indices.append(contentsOf: repeatElement(.min, count: position + 1 - indices.count))
        }
        indices[position] = slot.index
        return slot
    }
}

/// The process-wide table of types and the storage keys the build names.
/// Independently compiled modules agree on slots because every slot is
/// interned here on first use. The keys a session renders from variables
/// are a store's (`Keys`), not the process's.
@_spi(Generated)
public enum Registry {
    private struct State {
        var typeIDs: [String: TypeID] = [:]
        var typeNames: [String] = []
        /// By type, the index of every key interned on it.
        var slotIndices: [[String: Int32]] = []
        /// By type, the keys of the dense slots, by index.
        var slotKeys: [[String]] = []
        /// The slots of each connection type a plan describes, by `TypeID.raw`.
        var connections: [ConnectionSlots?] = []
        /// The slots of the schema extensions' fields, the client's: by type,
        /// the indices a payload committed by hand alone writes.
        var clientSlots: [Set<Int32>] = []
        /// By `TypeID.raw`, whether the type's records never reach the image.
        var transientTypes: [Bool] = []
        /// The root fields whose cells, keys and operations never reach the
        /// image, by the root type's number and the field's name.
        var transientFields: Set<TransientField> = []
    }

    /// A root field marked transient.
    struct TransientField: Hashable, Sendable {
        let type: TypeID
        let field: String
    }

    private static let state = Mutex(State())
    /// How many of the build's keys the process has numbered, on every type:
    /// a store compares it with what it has reconciled its own numbers
    /// against, without taking the lock.
    static let denseTotal = Atomic<Int>(0)

    public static func type(_ name: String, transient: Bool = false) -> TypeID {
        state.withLock { state in
            if let id = state.typeIDs[name] {
                if transient { state.transientTypes[Int(id.raw)] = true }
                return id
            }
            let id = TypeID(raw: Int32(state.typeNames.count))
            state.typeIDs[name] = id
            state.typeNames.append(name)
            state.slotIndices.append([:])
            state.slotKeys.append([])
            state.clientSlots.append([])
            state.transientTypes.append(transient)
            return id
        }
    }

    /// The slot of a key the build names, a constant the compiler emitted
    /// with arguments or without: dense, numbered on the type the first
    /// time it is met.
    public static func slot(_ type: TypeID, _ storageKey: String) -> Slot {
        state.withLock { state in
            let table = Int(type.raw)
            if let index = state.slotIndices[table][storageKey] { return Slot(type: type, index: index) }
            let index = Int32(state.slotKeys[table].count)
            state.slotKeys[table].append(storageKey)
            state.slotIndices[table][storageKey] = index
            denseTotal.wrappingAdd(1, ordering: .relaxed)
            return Slot(type: type, index: index)
        }
    }

    /// A slot of a schema extension's field: interned as any slot, and marked
    /// as the client's, so that a lens reading it absent reports nothing
    /// missing and asks for no heal; a payload committed by hand alone
    /// writes it.
    public static func clientSlot(_ type: TypeID, _ storageKey: String) -> Slot {
        let slot = slot(type, storageKey)
        state.withLock { _ = $0.clientSlots[Int(type.raw)].insert(slot.index) }
        return slot
    }

    /// Whether the slot is a schema extension's, which no server answers.
    static func isClient(_ slot: Slot) -> Bool {
        state.withLock { $0.clientSlots[Int(slot.type.raw)].contains(slot.index) }
    }

    /// Whether the type's records never reach the image.
    static func isTransient(_ type: TypeID) -> Bool {
        state.withLock { $0.transientTypes[Int(type.raw)] }
    }

    /// Marks a type's records as never reaching the image.
    static func markTransient(_ type: TypeID) {
        state.withLock { $0.transientTypes[Int(type.raw)] = true }
    }

    /// Marks a root field whose cells, storage keys and operations never
    /// reach the image, by the root type and the field's name; the writer
    /// asks by the name a storage key starts with.
    static func markTransient(_ type: TypeID, field: String) {
        state.withLock { _ = $0.transientFields.insert(TransientField(type: type, field: field)) }
    }

    /// Whether the root field a storage key names is transient.
    static func isTransientField(_ type: TypeID, storageKey: String) -> Bool {
        let name = storageKey.prefix { $0 != "(" }
        return state.withLock { $0.transientFields.contains(TransientField(type: type, field: String(name))) }
    }

    /// The build's keys numbered since `counts` last described each type's
    /// table, and the total numbered so far; `counts` is brought up to date.
    static func denseKeys(since counts: inout [Int]) -> (keys: [(type: TypeID, text: String, index: Int32)], total: Int) {
        state.withLock { state in
            var fresh: [(type: TypeID, text: String, index: Int32)] = []
            if counts.count < state.slotKeys.count { counts.append(contentsOf: repeatElement(0, count: state.slotKeys.count - counts.count)) }
            for table in state.slotKeys.indices {
                let keys = state.slotKeys[table]
                for index in counts[table]..<keys.count {
                    fresh.append((TypeID(raw: Int32(table)), keys[index], Int32(index)))
                }
                counts[table] = keys.count
            }
            return (fresh, denseTotal.load(ordering: .relaxed))
        }
    }

    /// The dense index of a key the build names on the type, when the
    /// process has met it: what a store asks before it numbers a rendering,
    /// so that a text has one slot.
    static func denseIndex(_ type: TypeID, _ storageKey: String) -> Int32? {
        state.withLock { $0.slotIndices[Int(type.raw)][storageKey] }
    }

    public static func typeName(_ type: TypeID) -> String {
        state.withLock { $0.typeNames[Int(type.raw)] }
    }

    /// Every type interned so far, by name.
    static func typeNames() -> [String] {
        state.withLock { $0.typeNames }
    }

    /// The text of a key the build names. A key a store numbered is named
    /// by the store.
    public static func storageKey(_ slot: Slot) -> String {
        precondition(slot.index >= 0, "a key a store numbered is named by the store")
        return state.withLock { $0.slotKeys[Int(slot.type.raw)][Int(slot.index)] }
    }

    /// How many of the build's keys have been interned on the type so far.
    public static func slotCount(_ type: TypeID) -> Int {
        state.withLock { $0.slotKeys[Int(type.raw)].count }
    }

    /// Keeps the slots a plan resolved for a connection type, under the type.
    static func register(_ slots: ConnectionSlots) {
        state.withLock { state in
            let position = Int(slots.connection.raw)
            if position >= state.connections.count {
                state.connections.append(contentsOf: repeatElement(nil, count: position + 1 - state.connections.count))
            }
            state.connections[position] = slots
        }
    }

    /// The slots of a connection type, when a plan has described one of it.
    static func connectionSlots(of type: TypeID) -> ConnectionSlots? {
        state.withLock { state in
            let position = Int(type.raw)
            return position < state.connections.count ? state.connections[position] : nil
        }
    }
}
