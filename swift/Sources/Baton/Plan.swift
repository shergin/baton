import Synchronization

/// An operation's normalization plan, emitted by the compiler as static data:
/// what the response contains and where each value is stored.
public struct Plan: Sendable {
    public let root: Selection

    public init(root: Selection) { self.root = root }

    /// Binds the variables: dynamic storage keys become slots, lookup keys
    /// become record keys, connections learn their merge mode and handles
    /// their connection ids. One resolution serves ingest, check and read.
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

/// The slots a connection's merge and state use, on the connection type, its
/// edge type and its page info type, plus the client fields Relay keeps on
/// the connection record. Resolved once per connection by the generated code.
public struct ConnectionSlots: Sendable {
    public let connection: TypeID
    public let edge: TypeID
    public let pageInfo: TypeID
    public let edges: Slot
    public let pageInfoLink: Slot
    public let node: Slot
    public let cursor: Slot
    public let hasNextPage: Slot
    public let hasPreviousPage: Slot
    public let startCursor: Slot
    public let endCursor: Slot
    public let isLoadingNext: Slot
    public let isLoadingPrevious: Slot
    public let nextEdgeIndex: Slot

    public init(connection: TypeID, edge: TypeID, pageInfo: TypeID) {
        self.connection = connection
        self.edge = edge
        self.pageInfo = pageInfo
        edges = Registry.slot(connection, "edges")
        pageInfoLink = Registry.slot(connection, "pageInfo")
        node = Registry.slot(edge, "node")
        cursor = Registry.slot(edge, "cursor")
        hasNextPage = Registry.slot(pageInfo, "hasNextPage")
        hasPreviousPage = Registry.slot(pageInfo, "hasPreviousPage")
        startCursor = Registry.slot(pageInfo, "startCursor")
        endCursor = Registry.slot(pageInfo, "endCursor")
        isLoadingNext = Registry.slot(connection, "__isLoadingNext")
        isLoadingPrevious = Registry.slot(connection, "__isLoadingPrevious")
        nextEdgeIndex = Registry.slot(connection, "__connection_next_edge_index")
    }
}

/// A cursor argument of a connection field: a variable, or a constant that is
/// not null (the compiler drops null constants).
public enum ConnectionCursor: Sendable {
    case variable(String)
    case literal
}

/// A `@connection` field: the client record its pages merge into, keyed on
/// the parent by Relay's handle key, and the cursor arguments that decide
/// whether a page replaces, appends or prepends.
public struct ConnectionPlan: Sendable {
    public let key: StorageKey
    public let slots: ConnectionSlots
    public let after: ConnectionCursor?
    public let before: ConnectionCursor?

    public init(key: StorageKey, slots: ConnectionSlots, after: ConnectionCursor? = nil, before: ConnectionCursor? = nil) {
        self.key = key
        self.slots = slots
        self.after = after
        self.before = before
    }
}

/// How a page joins its connection, from the cursor arguments it was fetched
/// with: as in Relay's connection handler.
public enum ConnectionMode: Sendable, Equatable {
    /// No cursor: the connection becomes this page.
    case replace
    /// Fetched after a cursor: appended, when the cursor is still the end.
    case append(after: String?)
    /// Fetched before a cursor: prepended, when the cursor is still the start.
    case prepend(before: String?)
}

/// An edge directive on a mutation payload field, as Relay's handle: what to
/// do with the field's records once the payload is in the store.
public struct Handle: Sendable {
    public enum Kind: Sendable {
        case appendEdge, prependEdge, appendNode, prependNode, deleteEdge, deleteRecord
    }

    /// The connection ids the directive names: a variable, or a constant list.
    public enum Connections: Sendable {
        case variable(String)
        case literal([String])
    }

    public let kind: Kind
    public let connections: Connections?
    /// The edge type `@appendNode`/`@prependNode` wrap the node in.
    public let edgeType: TypeID?

    public init(kind: Kind, connections: Connections? = nil, edgeType: TypeID? = nil) {
        self.kind = kind
        self.connections = connections
        self.edgeType = edgeType
    }
}

/// How a `@refetchable` fragment's query is bound from a lens: the query's
/// variables (taken from the lens's scope), the one that carries the owner's
/// id, and the connection's count and cursor variables for pagination.
public struct Refetch: Sendable {
    public let variables: [String]
    public let identifier: String?
    public let first: String?
    public let after: String?
    public let last: String?
    public let before: String?

    public init(variables: [String], identifier: String?, first: String?, after: String?, last: String?, before: String?) {
        self.variables = variables
        self.identifier = identifier
        self.first = first
        self.after = after
        self.last = last
        self.before = before
    }
}

public struct PlanField: Sendable {
    public enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(Selection, plural: Bool, lookup: Lookup?, connection: ConnectionPlan?)
    }

    public let responseKey: String
    public let key: StorageKey
    public let kind: Kind
    public let handle: Handle?

    public static func scalar(_ responseKey: String, key: StorageKey, kind: ScalarKind, list: Bool, handle: Handle? = nil) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .scalar(kind, list: list), handle: handle)
    }

    public static func linked(_ responseKey: String, key: StorageKey, plural: Bool, lookup: Lookup? = nil, connection: ConnectionPlan? = nil, handle: Handle? = nil, selection: Selection) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .linked(selection, plural: plural, lookup: lookup, connection: connection), handle: handle)
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
                let storageKey = Selection.render(field.key, variables)
                let slot = Selection.slot(field.key, storageKey, on: type)
                let kind: ResolvedField.Kind = switch field.kind {
                case .scalar(let scalar, let list): .scalar(scalar, list: list)
                case .linked(let selection, let plural, let lookup, let connection):
                    .linked(
                        selection.resolve(variables),
                        plural: plural,
                        lookupKey: lookup.map { lookup in
                            let value = switch lookup.key {
                            case .variable(let name): variables.keyText(name)
                            case .literal(let text): text
                            }
                            return LookupKey(type: lookup.type, value: value)
                        },
                        connection: connection.map { connection in
                            let key = Selection.render(connection.key, variables)
                            return ResolvedConnection(
                                storageKey: key,
                                slot: Selection.slot(connection.key, key, on: type),
                                slots: connection.slots,
                                mode: Selection.mode(connection, variables)
                            )
                        }
                    )
                }
                return ResolvedField(
                    responseKey: field.responseKey,
                    storageKey: storageKey,
                    slot: slot,
                    kind: kind,
                    handle: field.handle.map { handle in
                        ResolvedHandle(
                            kind: handle.kind,
                            connections: Selection.connections(handle.connections, variables),
                            edgeType: handle.edgeType
                        )
                    }
                )
            }
        )
    }

    private static func render(_ key: StorageKey, _ variables: Variables) -> String {
        switch key {
        case .fixed(let slot): slot.storageKey
        case .dynamic(let parts):
            parts.map { part in
                switch part {
                case .literal(let text): text
                case .variable(let name): variables.render(name)
                }
            }.joined()
        }
    }

    private static func slot(_ key: StorageKey, _ storageKey: String, on type: TypeID) -> Slot {
        switch key {
        case .fixed(let slot): slot
        case .dynamic: Registry.slot(type, storageKey)
        }
    }

    /// The merge mode of a connection page, from the cursor the field was
    /// fetched with: a present `after` appends, a present `before` prepends.
    private static func mode(_ connection: ConnectionPlan, _ variables: Variables) -> ConnectionMode {
        func cursor(_ argument: ConnectionCursor?) -> (present: Bool, value: String?) {
            switch argument {
            case .none: return (false, nil)
            case .literal: return (true, nil)
            case .variable(let name):
                guard let value = variables[name], value != .null else { return (false, nil) }
                return (true, value.keyText)
            }
        }
        let after = cursor(connection.after)
        if after.present { return .append(after: after.value) }
        let before = cursor(connection.before)
        if before.present { return .prepend(before: before.value) }
        return .replace
    }

    /// The connection ids a handle names, from its variable or constant list.
    private static func connections(_ connections: Handle.Connections?, _ variables: Variables) -> [String] {
        switch connections {
        case .none: return []
        case .literal(let keys): return keys
        case .variable(let name):
            switch variables[name] {
            case .list(let items)?: return items.map(\.keyText)
            case .string(let key)?: return [key]
            default: return []
            }
        }
    }
}

/// A bound lookup: the record key `Type:value`, or the id alone across types.
public struct LookupKey: Sendable {
    public let type: TypeID?
    public let value: String

    var recordKey: String? { type.map { $0.name + ":" + value } }
}

/// A connection with its variables bound: the client key on the parent, the
/// slots, and how the page it describes joins the connection. A class, so a
/// field's kind stays one word wide and the ingest copies nothing per key.
public final class ResolvedConnection: Sendable {
    public let storageKey: String
    /// The client slot on the selection's declared type; abstract selections
    /// resolve it per concrete type instead.
    public let slot: Slot
    public let slots: ConnectionSlots
    public let mode: ConnectionMode

    init(storageKey: String, slot: Slot, slots: ConnectionSlots, mode: ConnectionMode) {
        self.storageKey = storageKey
        self.slot = slot
        self.slots = slots
        self.mode = mode
    }
}

/// A handle with its connection ids bound.
public final class ResolvedHandle: Sendable {
    public let kind: Handle.Kind
    public let connections: [String]
    public let edgeType: TypeID?

    init(kind: Handle.Kind, connections: [String], edgeType: TypeID?) {
        self.kind = kind
        self.connections = connections
        self.edgeType = edgeType
    }
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

    /// The client slot of a connection on a record, honoring abstract selections.
    func slot(of connection: ResolvedConnection, on type: TypeID) -> Slot {
        isAbstract ? Registry.slot(type, connection.storageKey) : connection.slot
    }
}

public struct ResolvedField: Sendable {
    public enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(ResolvedSelection, plural: Bool, lookupKey: LookupKey?, connection: ResolvedConnection?)
    }

    public let responseKey: String
    let keyBytes: [UInt8]
    public let storageKey: String
    /// The slot on the selection's declared type; abstract selections resolve
    /// per concrete type instead.
    public let slot: Slot
    public let kind: Kind
    public let handle: ResolvedHandle?
    let isTypename: Bool

    init(responseKey: String, storageKey: String, slot: Slot, kind: Kind, handle: ResolvedHandle?) {
        self.responseKey = responseKey
        keyBytes = Array(responseKey.utf8)
        self.storageKey = storageKey
        self.slot = slot
        self.kind = kind
        self.handle = handle
        isTypename = responseKey == "__typename"
    }
}
