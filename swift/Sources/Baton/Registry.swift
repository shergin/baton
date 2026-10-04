import Synchronization

/// An interned schema type.
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
/// and per id, has a negative index, numbered apart, and a record keeps it
/// in a short list of the keys written to it, so the keys a session makes
/// never widen the records of their type. Generated code holds slots as
/// `static let`s; an app meets one only in the store's reports, which name
/// it by its key.
public struct Slot: Hashable, Sendable {
    @_spi(Generated) public let type: TypeID
    @_spi(Generated) public let index: Int32

    public var storageKey: String { Registry.storageKey(self) }
}

/// A storage key read on whatever concrete type a record has: a field
/// selected on an interface or union. The slot of each type is resolved on
/// its first read there, so every later read is two array loads.
@_spi(Generated)
@MainActor
public final class AbstractSlot {
    nonisolated public let storageKey: String
    /// Whether the key was rendered from variables, which numbers it apart
    /// on a type that has not met it.
    nonisolated let rendered: Bool
    /// Slot index by `TypeID.raw`; `Int32.min` until the type is first read.
    private var indices: ContiguousArray<Int32> = []

    nonisolated public convenience init(_ storageKey: String) {
        self.init(storageKey, rendered: false)
    }

    nonisolated init(_ storageKey: String, rendered: Bool) {
        self.storageKey = storageKey
        self.rendered = rendered
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
        let slot = Registry.slot(type, storageKey, rendered: rendered)
        let position = Int(type.raw)
        if position >= indices.count {
            indices.append(contentsOf: repeatElement(.min, count: position + 1 - indices.count))
        }
        indices[position] = slot.index
        return slot
    }
}

/// The process-wide table of types and storage keys. Independently compiled
/// modules agree on slots because every slot is interned here on first use.
@_spi(Generated)
public enum Registry {
    private struct State {
        var typeIDs: [String: TypeID] = [:]
        var typeNames: [String] = []
        /// By type, the index of every key interned on it, of either kind.
        var slotIndices: [[String: Int32]] = []
        /// By type, the keys of the dense slots, by index.
        var slotKeys: [[String]] = []
        /// By type, the keys numbered apart: the one at `n` has index `~n`.
        var renderedKeys: [[String]] = []
        /// The slots of each connection type a plan describes, by `TypeID.raw`.
        var connections: [ConnectionSlots?] = []
    }

    private static let state = Mutex(State())

    public static func type(_ name: String) -> TypeID {
        state.withLock { state in
            if let id = state.typeIDs[name] { return id }
            let id = TypeID(raw: Int32(state.typeNames.count))
            state.typeIDs[name] = id
            state.typeNames.append(name)
            state.slotIndices.append([:])
            state.slotKeys.append([])
            state.renderedKeys.append([])
            return id
        }
    }

    /// The slot of a key the compiler emitted as a constant: a dense one,
    /// unless the process met the key's text first rendered or in the image.
    public static func slot(_ type: TypeID, _ storageKey: String) -> Slot {
        slot(type, storageKey, rendered: false)
    }

    /// The slot of a storage key on a type. A key the type has not met is
    /// numbered apart when it was rendered from variables, and densely
    /// otherwise. The kind is decided then, once: a key's text has one slot
    /// in a process, whether a constant or a rendering meets it later.
    static func slot(_ type: TypeID, _ storageKey: String, rendered: Bool) -> Slot {
        state.withLock { state in
            let table = Int(type.raw)
            if let index = state.slotIndices[table][storageKey] { return Slot(type: type, index: index) }
            let index: Int32
            if rendered {
                index = ~Int32(state.renderedKeys[table].count)
                state.renderedKeys[table].append(storageKey)
            } else {
                index = Int32(state.slotKeys[table].count)
                state.slotKeys[table].append(storageKey)
            }
            state.slotIndices[table][storageKey] = index
            return Slot(type: type, index: index)
        }
    }

    public static func typeName(_ type: TypeID) -> String {
        state.withLock { $0.typeNames[Int(type.raw)] }
    }

    /// Every type interned so far, by name.
    static func typeNames() -> [String] {
        state.withLock { $0.typeNames }
    }

    public static func storageKey(_ slot: Slot) -> String {
        state.withLock { state in
            let table = Int(slot.type.raw)
            return slot.index >= 0 ? state.slotKeys[table][Int(slot.index)] : state.renderedKeys[table][Int(~slot.index)]
        }
    }

    /// How many storage keys have been interned on the type so far, of
    /// either kind.
    public static func slotCount(_ type: TypeID) -> Int {
        state.withLock { $0.slotKeys[Int(type.raw)].count + $0.renderedKeys[Int(type.raw)].count }
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
