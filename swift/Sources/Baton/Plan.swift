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
/// is missing from the store, the entity `Type:key` satisfies it.
public struct Lookup: Sendable {
    public enum Key: Sendable {
        case variable(String)
        case literal(String)
    }

    public let type: TypeID
    public let key: Key

    public init(type: TypeID, key: Key) {
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

/// A selection set on one type.
public final class Selection: Sendable {
    public let type: TypeID
    public let hasID: Bool
    public let fields: [PlanField]

    public init(type: TypeID, hasID: Bool, fields: [PlanField]) {
        self.type = type
        self.hasID = hasID
        self.fields = fields
    }

    func resolve(_ variables: Variables) -> ResolvedSelection {
        ResolvedSelection(
            type: type,
            hasID: hasID,
            fields: fields.map { field in
                let slot: Slot = switch field.key {
                case .fixed(let slot): slot
                case .dynamic(let parts):
                    Registry.slot(type, parts.map { part in
                        switch part {
                        case .literal(let text): text
                        case .variable(let name): variables.render(name)
                        }
                    }.joined())
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
                            return (lookup.type, lookup.type.name + ":" + value)
                        }
                    )
                }
                return ResolvedField(responseKey: field.responseKey, slot: slot, kind: kind)
            }
        )
    }
}

/// A plan with variables bound: slots instead of keys, byte keys for matching.
public final class ResolvedSelection: Sendable {
    public let type: TypeID
    public let hasID: Bool
    public let fields: [ResolvedField]

    init(type: TypeID, hasID: Bool, fields: [ResolvedField]) {
        self.type = type
        self.hasID = hasID
        self.fields = fields
    }
}

public struct ResolvedField: Sendable {
    public enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(ResolvedSelection, plural: Bool, lookupKey: (TypeID, String)?)
    }

    public let responseKey: String
    let keyBytes: [UInt8]
    public let slot: Slot
    public let kind: Kind

    init(responseKey: String, slot: Slot, kind: Kind) {
        self.responseKey = responseKey
        keyBytes = Array(responseKey.utf8)
        self.slot = slot
        self.kind = kind
    }
}
