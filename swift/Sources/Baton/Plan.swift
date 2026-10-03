import Synchronization

/// An operation's normalization plan, emitted by the compiler as static data:
/// what the response contains and where each value is stored.
public struct Plan: Sendable {
    public let root: Selection

    public init(root: Selection) { self.root = root }

    /// Binds the variables: dynamic storage keys become slots and lookup keys
    /// become record keys. One resolution serves ingest, check and read.
    public func resolve(_ variables: Variables) -> ResolvedSelection {
        root.resolve(variables)
    }
}

public enum ScalarKind: Sendable {
    case string, int, double, bool, custom
}

public enum KeyPart: Sendable {
    case literal(String)
    case variable(String)
}

/// Where a field's value lives on its parent record.
public enum StorageKey: Sendable {
    case fixed(Slot)
    /// A key with variables, e.g. `characters(page:$page)`.
    case dynamic([KeyPart])
}

/// A root field that returns an entity by one of its arguments. When the link
/// is missing from the store, the entity satisfies it: `Type:key` when the
/// type is known, or the record with that id across types when it is not
/// (`node(id:)`).
public struct Lookup: Sendable {
    public enum Key: Sendable {
        case variable(String)
        case literal(String)
    }

    public let type: TypeID?
    public let key: Key

    public init(type: TypeID?, key: Key) {
        self.type = type
        self.key = key
    }
}

public struct PlanField: Sendable {
    public enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(Selection, plural: Bool, lookup: Lookup?)
    }

    public let responseKey: String
    public let key: StorageKey
    public let kind: Kind

    public static func scalar(_ responseKey: String, key: StorageKey, kind: ScalarKind, list: Bool) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .scalar(kind, list: list))
    }

    public static func linked(_ responseKey: String, key: StorageKey, plural: Bool, lookup: Lookup? = nil, selection: Selection) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .linked(selection, plural: plural, lookup: lookup))
    }
}

/// A selection set on one type. When the type is an interface or union, the
/// payload's `__typename` decides the record's concrete type, and slots are
/// resolved against that type.
public final class Selection: Sendable {
    public let type: TypeID
    public let hasID: Bool
    public let isAbstract: Bool
    public let fields: [PlanField]

    public init(type: TypeID, hasID: Bool, abstract: Bool = false, fields: [PlanField]) {
        self.type = type
        self.hasID = hasID
        isAbstract = abstract
        self.fields = fields
    }

    func resolve(_ variables: Variables) -> ResolvedSelection {
        ResolvedSelection(
            type: type,
            hasID: hasID,
            isAbstract: isAbstract,
            fields: fields.map { field in
                let storageKey: String = switch field.key {
                case .fixed(let slot): slot.storageKey
                case .dynamic(let parts):
                    parts.map { part in
                        switch part {
                        case .literal(let text): text
                        case .variable(let name): variables.render(name)
                        }
                    }.joined()
                }
                let slot: Slot = switch field.key {
                case .fixed(let slot): slot
                case .dynamic: Registry.slot(type, storageKey)
                }
                let kind: ResolvedField.Kind = switch field.kind {
                case .scalar(let scalar, let list): .scalar(scalar, list: list)
                case .linked(let selection, let plural, let lookup):
                    .linked(
                        selection.resolve(variables),
                        plural: plural,
                        lookupKey: lookup.map { lookup in
                            let value = switch lookup.key {
                            case .variable(let name): variables.keyText(name)
                            case .literal(let text): text
                            }
                            return LookupKey(type: lookup.type, value: value)
                        }
                    )
                }
                return ResolvedField(responseKey: field.responseKey, storageKey: storageKey, slot: slot, kind: kind)
            }
        )
    }
}

/// A bound lookup: the record key `Type:value`, or the id alone across types.
public struct LookupKey: Sendable {
    public let type: TypeID?
    public let value: String

    var recordKey: String? { type.map { $0.name + ":" + value } }
}

/// A plan with variables bound: slots instead of keys, byte keys for matching.
public final class ResolvedSelection: Sendable {
    public let type: TypeID
    public let hasID: Bool
    public let isAbstract: Bool
    public let fields: [ResolvedField]
    private let concreteSlots = Mutex<[TypeID: [Slot]]>([:])

    init(type: TypeID, hasID: Bool, isAbstract: Bool, fields: [ResolvedField]) {
        self.type = type
        self.hasID = hasID
        self.isAbstract = isAbstract
        self.fields = fields
    }

    /// The slots of this selection's fields on a concrete type, for selections
    /// on interfaces and unions. Cached per type.
    func slots(for concrete: TypeID) -> [Slot] {
        concreteSlots.withLock { cache in
            if let slots = cache[concrete] { return slots }
            let slots = fields.map { Registry.slot(concrete, $0.storageKey) }
            cache[concrete] = slots
            return slots
        }
    }

    /// The slot of a field on a record, honoring abstract selections.
    @inline(__always)
    func slot(of index: Int, on type: TypeID) -> Slot {
        isAbstract ? slots(for: type)[index] : fields[index].slot
    }
}

public struct ResolvedField: Sendable {
    public enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(ResolvedSelection, plural: Bool, lookupKey: LookupKey?)
    }

    public let responseKey: String
    let keyBytes: [UInt8]
    public let storageKey: String
    /// The slot on the selection's declared type; abstract selections resolve
    /// per concrete type instead.
    public let slot: Slot
    public let kind: Kind
    let isTypename: Bool

    init(responseKey: String, storageKey: String, slot: Slot, kind: Kind) {
        self.responseKey = responseKey
        keyBytes = Array(responseKey.utf8)
        self.storageKey = storageKey
        self.slot = slot
        self.kind = kind
        isTypename = responseKey == "__typename"
    }
}
