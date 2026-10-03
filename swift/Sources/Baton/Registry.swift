import Synchronization

/// An interned schema type.
public struct TypeID: Hashable, Sendable {
    public let raw: Int32

    /// The type's name, for keys and diagnostics.
    public var name: String { Registry.typeName(self) }
}

/// An interned storage key of one type: the dense index a record stores the
/// field's value at. Generated code holds slots as `static let`s.
public struct Slot: Hashable, Sendable {
    public let type: TypeID
    public let index: Int32

    public var storageKey: String { Registry.storageKey(self) }
}

/// The process-wide table of types and storage keys. Independently compiled
/// modules agree on slots because every slot is interned here on first use.
public enum Registry {
    private struct State {
        var typeIDs: [String: TypeID] = [:]
        var typeNames: [String] = []
        var slotIndices: [[String: Int32]] = []
        var slotKeys: [[String]] = []
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
            return id
        }
    }

    public static func slot(_ type: TypeID, _ storageKey: String) -> Slot {
        state.withLock { state in
            let table = Int(type.raw)
            if let index = state.slotIndices[table][storageKey] { return Slot(type: type, index: index) }
            let index = Int32(state.slotKeys[table].count)
            state.slotIndices[table][storageKey] = index
            state.slotKeys[table].append(storageKey)
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
        state.withLock { $0.slotKeys[Int(slot.type.raw)][Int(slot.index)] }
    }

    /// How many storage keys the type has so far; records size their values to it.
    public static func slotCount(_ type: TypeID) -> Int {
        state.withLock { $0.slotKeys[Int(type.raw)].count }
    }
}
