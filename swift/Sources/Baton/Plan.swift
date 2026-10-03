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
    case dynamic(DynamicKey)
}

/// A root field that returns an entity by one of its arguments. When the link
/// is missing from the store, the entity satisfies it: `Type:key` when the
/// type is known, or the one live record `T:key` among the field's possible
/// types when it is not (`node(id:)`).
public struct Lookup: Sendable {
    public enum Key: Sendable {
        case variable(String)
        case literal(String)
    }

    public let type: TypeID?
    /// The concrete types a lookup without a type probes.
    public let possibleTypes: Set<TypeID>
    public let key: Key

    public init(type: TypeID?, possibleTypes: Set<TypeID> = [], key: Key) {
        self.type = type
        self.possibleTypes = possibleTypes
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

/// One condition of `@include` or `@skip`: the variable, and the value it
/// must have for the field to be fetched.
public struct Guard: Sendable {
    public let variable: String
    public let passing: Bool

    public init(_ variable: String, passing: Bool) {
        self.variable = variable
        self.passing = passing
    }

    func holds(_ variables: Variables) -> Bool {
        variables[variable] == .bool(passing)
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
    /// The `@defer` label of the part that carries the field, when deferred.
    public let deferred: String?
    /// Whether the field or an ancestor carries `@catch`, so an error on it
    /// does not fail a `@throwOnFieldError` operation.
    public let caught: Bool
    /// Alternatives of conjunctions of `@include` and `@skip` conditions: the
    /// field is fetched when any alternative holds. Empty when it always is.
    public let guards: [[Guard]]

    public static func scalar(_ responseKey: String, key: StorageKey, kind: ScalarKind, list: Bool, handle: Handle? = nil, deferred: String? = nil, caught: Bool = false, guards: [[Guard]] = []) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .scalar(kind, list: list), handle: handle, deferred: deferred, caught: caught, guards: guards)
    }

    public static func linked(_ responseKey: String, key: StorageKey, plural: Bool, lookup: Lookup? = nil, connection: ConnectionPlan? = nil, handle: Handle? = nil, deferred: String? = nil, caught: Bool = false, guards: [[Guard]] = [], selection: Selection) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .linked(selection, plural: plural, lookup: lookup, connection: connection), handle: handle, deferred: deferred, caught: caught, guards: guards)
    }

    /// Whether the variables select the field.
    func selected(by variables: Variables) -> Bool {
        guards.isEmpty || guards.contains { conjunction in conjunction.allSatisfy { $0.holds(variables) } }
    }
}

/// A selection set on one type. On an interface or union, the payload's
/// `__typename` names each record's concrete type, and the type picks the
/// variant: the fields that type reads.
public final class Selection: Sendable {
    /// The fields one group of concrete types reads.
    public struct Variant: Sendable {
        /// The concrete types the variant serves; `nil` serves every other type.
        public let types: [TypeID]?
        public let fields: [PlanField]

        public init(types: [TypeID]?, fields: [PlanField]) {
            self.types = types
            self.fields = fields
        }
    }

    public let type: TypeID
    public let hasID: Bool
    public let isAbstract: Bool
    public let variants: [Variant]

    /// A selection every type reads alike.
    public convenience init(type: TypeID, hasID: Bool, abstract: Bool = false, fields: [PlanField]) {
        self.init(type: type, hasID: hasID, abstract: abstract, variants: [Variant(types: nil, fields: fields)])
    }

    public init(type: TypeID, hasID: Bool, abstract: Bool = false, variants: [Variant]) {
        self.type = type
        self.hasID = hasID
        isAbstract = abstract
        self.variants = variants
    }

    /// Binds the variables: fields whose guards fail are dropped, keys with
    /// variables are rendered, and each listed type's variant is resolved
    /// now; every other type's is resolved from the shared fields when a
    /// record of it first comes.
    func resolve(_ variables: Variables) -> ResolvedSelection {
        var listed: [TypeID: ResolvedVariant] = [:]
        var others: [ResolvedField] = []
        for variant in variants {
            let fields = variant.fields.filter { $0.selected(by: variables) }.map { resolve($0, variables) }
            guard let types = variant.types else {
                others = fields
                continue
            }
            for concrete in types {
                listed[concrete] = ResolvedVariant(type: concrete, fields: fields.map { $0.on(concrete) })
            }
        }
        return ResolvedSelection(type: type, hasID: hasID, isAbstract: isAbstract, fields: others, listed: listed)
    }

    /// A field with its variables bound, its slot on the selection's own type.
    private func resolve(_ field: PlanField, _ variables: Variables) -> ResolvedField {
        let storageKey = Selection.render(field.key, variables)
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
                    return LookupKey(type: lookup.type, possibleTypes: lookup.possibleTypes, value: value)
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
            slot: Selection.slot(field.key, storageKey, on: type),
            kind: kind,
            handle: field.handle.map { handle in
                ResolvedHandle(
                    kind: handle.kind,
                    connections: Selection.connections(handle.connections, variables),
                    edgeType: handle.edgeType
                )
            },
            deferred: field.deferred,
            caught: field.caught
        )
    }

    private static func render(_ key: StorageKey, _ variables: Variables) -> String {
        switch key {
        case .fixed(let slot): slot.storageKey
        case .dynamic(let key): key.render(variables)
        }
    }

    private static func slot(_ key: StorageKey, _ storageKey: String, on type: TypeID) -> Slot {
        switch key {
        case .fixed(let slot) where slot.type == type: slot
        case .fixed, .dynamic: Registry.slot(type, storageKey)
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

/// A bound lookup: the record key `Type:value`, or the id among the
/// possible types.
public struct LookupKey: Sendable {
    public let type: TypeID?
    public let possibleTypes: Set<TypeID>
    public let value: String
}

/// A connection with its variables bound: the client key on the parent, the
/// slots, and how the page it describes joins the connection. A class, so a
/// field's kind stays one word wide and the ingest copies nothing per key.
public final class ResolvedConnection: Sendable {
    public let storageKey: String
    /// The client slot on the variant's concrete type.
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

/// A plan with variables bound: per concrete type, the fields a record of
/// that type reads, with their slots on it and their keys as bytes.
public final class ResolvedSelection: Sendable {
    public let type: TypeID
    public let hasID: Bool
    /// Whether a record's type comes from the payload's `__typename`.
    public let isAbstract: Bool
    /// The fields of a selection on an object type; on an abstract type,
    /// those every type reads, resolved on the abstract type itself for a
    /// record whose payload names no type. Stored apart from a variant so
    /// the walks over object types read it without retaining it.
    let fields: [ResolvedField]
    private let listed: [TypeID: ResolvedVariant]
    /// The variants of types the plan does not list, from `base`'s fields,
    /// resolved when a record of the type first comes.
    private let others = Mutex<[TypeID: ResolvedVariant]>([:])
    private let deferredParts = Mutex<[String: ResolvedSelection]>([:])

    init(type: TypeID, hasID: Bool, isAbstract: Bool, fields: [ResolvedField], listed: [TypeID: ResolvedVariant]) {
        self.type = type
        self.hasID = hasID
        self.isAbstract = isAbstract
        self.fields = fields
        self.listed = listed
    }

    /// The fields a record of `type` reads, with their slots on it. Taken
    /// once per record; the fields are then walked without a condition.
    public func variant(for type: TypeID) -> ResolvedVariant {
        if !isAbstract || type == self.type { return ResolvedVariant(type: self.type, fields: fields) }
        if let variant = listed[type] { return variant }
        return others.withLock { cache in
            if let variant = cache[type] { return variant }
            let variant = ResolvedVariant(type: type, fields: fields.map { $0.on(type) })
            cache[type] = variant
            return variant
        }
    }

    /// The selection an incremental part with this `@defer` label fills: the
    /// fields the label marks, on the same record. Cached per label.
    func deferred(_ label: String) -> ResolvedSelection? {
        deferredParts.withLock { cache in
            if let part = cache[label] { return part }
            func part(_ variant: ResolvedVariant) -> ResolvedVariant {
                ResolvedVariant(type: variant.type, fields: variant.fields.filter { $0.deferred == label }.map { $0.undeferred() })
            }
            let own = fields.filter { $0.deferred == label }.map { $0.undeferred() }
            let selection = ResolvedSelection(type: type, hasID: hasID, isAbstract: isAbstract, fields: own, listed: listed.mapValues(part))
            guard !own.isEmpty || selection.listed.values.contains(where: { !$0.fields.isEmpty }) else { return nil }
            cache[label] = selection
            return selection
        }
    }
}

/// The fields a record of one concrete type reads, with their slots on it.
public struct ResolvedVariant: Sendable {
    public let type: TypeID
    public let fields: [ResolvedField]

    /// The field with a response key, for walking a response path.
    func field(named responseKey: String) -> Int? {
        fields.firstIndex { $0.responseKey == responseKey }
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
    /// The slot on the variant's concrete type.
    public let slot: Slot
    public let kind: Kind
    public let handle: ResolvedHandle?
    /// The `@defer` label of the part that carries the field; the availability
    /// check does not wait for it.
    public let deferred: String?
    public let caught: Bool
    let isTypename: Bool

    init(responseKey: String, storageKey: String, slot: Slot, kind: Kind, handle: ResolvedHandle?, deferred: String?, caught: Bool) {
        self.responseKey = responseKey
        keyBytes = Array(responseKey.utf8)
        self.storageKey = storageKey
        self.slot = slot
        self.kind = kind
        self.handle = handle
        self.deferred = deferred
        self.caught = caught
        isTypename = responseKey == "__typename"
    }

    /// The same field as the incremental part delivers it: no longer deferred.
    func undeferred() -> ResolvedField {
        ResolvedField(responseKey: responseKey, storageKey: storageKey, slot: slot, kind: kind, handle: handle, deferred: nil, caught: caught)
    }

    /// The same field on another concrete type: its slot, and its
    /// connection's, interned there.
    func on(_ type: TypeID) -> ResolvedField {
        if slot.type == type { return self }
        let kind: Kind = switch kind {
        case .scalar: kind
        case .linked(let child, let plural, let lookupKey, let connection):
            .linked(child, plural: plural, lookupKey: lookupKey, connection: connection.map { connection in
                ResolvedConnection(storageKey: connection.storageKey, slot: Registry.slot(type, connection.storageKey), slots: connection.slots, mode: connection.mode)
            })
        }
        return ResolvedField(responseKey: responseKey, storageKey: storageKey, slot: Registry.slot(type, storageKey), kind: kind, handle: handle, deferred: deferred, caught: caught)
    }
}
