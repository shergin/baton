import Synchronization

/// The format of the generated code this runtime reads: what that code names
/// in the runtime, from the plan tables to the lens requirements. Every
/// shared file the compiler writes names the marker of its format, so
/// generated code of another format fails to compile at that one line, and
/// the message there says which side is behind. When the format changes, a
/// new marker is declared and the one before it stays, unavailable, with
/// the message. The compiler's `FORMAT` is the same number.
@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 1 and the runtime reads format 3; rebuild with the compiler of this release")
public enum Format1 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 2 and the runtime reads format 4; rebuild with the compiler of this release")
public enum Format2 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 3 and the runtime reads format 4: a type condition is tested against members the build compiled and a response said, and a selection carries Relay's membership answers; rebuild with the compiler of this release")
public enum Format3 {}

@_spi(Generated)
public enum Format4 {}

/// An operation's normalization plan, emitted by the compiler as static data:
/// what the response contains and where each value is stored.
@_spi(Generated)
public struct Plan: Sendable {
    public let root: Selection

    public init(root: Selection) { self.root = root }

    /// Binds the variables: dynamic storage keys become slots, numbered by
    /// `keys`, the store's, lookup keys become record keys, connections learn
    /// their merge mode and handles their connection ids. One resolution
    /// serves ingest, check and read, in the store whose keys numbered it.
    package func resolve(_ variables: Variables, in keys: Keys) -> ResolvedSelection {
        keys.reconcile()
        return root.resolve(variables, keys.hold())
    }
}

@_spi(Generated)
public enum ScalarKind: Sendable {
    case string, int, double, bool, custom
}

@_spi(Generated)
public enum KeyPart: Sendable {
    case literal(String)
    case variable(String)
}

/// Where a field's value lives on its parent record.
@_spi(Generated)
public enum StorageKey: Sendable {
    case fixed(Slot)
    /// A key with variables, e.g. `characters(page:$page)`.
    case dynamic(DynamicKey)

    /// Whether the key is rendered from variables, and so numbered apart.
    var isRendered: Bool {
        if case .dynamic = self { return true }
        return false
    }
}

/// A root field that returns an entity by one of its arguments. When the link
/// is missing from the store, the entity satisfies it: `Type:key` when the
/// type is known, or the one live record `T:key` among the field's possible
/// types when it is not (`node(id:)`).
@_spi(Generated)
public struct Lookup: Sendable {
    public enum Key: Sendable {
        case variable(String)
        case literal(String)
    }

    public let type: TypeID?
    /// The types a lookup without a type probes: the members the build
    /// compiled for the field's interface or union.
    public let possibleTypes: Members?
    public let key: Key

    public init(type: TypeID?, possibleTypes: Members? = nil, key: Key) {
        self.type = type
        self.possibleTypes = possibleTypes
        self.key = key
    }
}

/// The slots a connection's merge and state use, on the connection type, its
/// edge type and its page info type, plus the client fields Relay keeps on
/// the connection record. Resolved once per connection by the generated code,
/// and kept by the registry under the connection type, where the commit of
/// an edge directive, which names its connections by id, finds them.
@_spi(Generated)
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
        Registry.register(self)
    }
}

/// A cursor argument of a connection field: a variable, or a constant that is
/// not null (the compiler drops null constants).
@_spi(Generated)
public enum ConnectionCursor: Sendable {
    case variable(String)
    case literal
}

/// A `@connection` field: the client record its pages merge into, keyed on
/// the parent by Relay's handle key, and the cursor arguments that decide
/// whether a page replaces, appends or prepends.
@_spi(Generated)
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

    /// Whether the connection's key or its merge mode reads a variable.
    var readsVariables: Bool {
        if case .dynamic = key { return true }
        if case .variable? = after { return true }
        if case .variable? = before { return true }
        return false
    }
}

/// How a page joins its connection, from the cursor arguments it was fetched
/// with: as in Relay's connection handler.
package enum ConnectionMode: Sendable, Equatable {
    /// No cursor: the connection becomes this page.
    case replace
    /// Fetched after a cursor: appended, when the cursor is still the end.
    case append(after: String?)
    /// Fetched before a cursor: prepended, when the cursor is still the start.
    case prepend(before: String?)
}

/// An edge directive on a mutation payload field: the edit to make with the
/// field's records once the payload is in the store, which the change set
/// carries as a `ChangeSet.Edit`.
@_spi(Generated)
public struct Edit: Sendable {
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
@_spi(Generated)
public struct Refetch: Sendable {
    public let variables: [String]
    public let identifier: String?
    /// The slot the owner's id is read from, when the query takes one.
    public let identity: Slot?
    public let first: String?
    public let after: String?
    public let last: String?
    public let before: String?

    public init(variables: [String], identifier: String?, identity: Slot?, first: String?, after: String?, last: String?, before: String?) {
        self.variables = variables
        self.identifier = identifier
        self.identity = identity
        self.first = first
        self.after = after
        self.last = last
        self.before = before
    }
}

/// One condition of `@include` or `@skip`: the variable, and the value it
/// must have for the field to be fetched.
@_spi(Generated)
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

@_spi(Generated)
public struct PlanField: Sendable {
    public enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(Selection, plural: Bool, lookup: Lookup?, connection: ConnectionPlan?)
    }

    public let responseKey: String
    public let key: StorageKey
    public let kind: Kind
    public let edit: Edit?
    /// The `@defer` label of the part that carries the field, when deferred.
    public let deferred: String?
    /// Whether the field or an ancestor carries `@catch`, so an error on it
    /// does not fail a `@throwOnFieldError` operation.
    public let caught: Bool
    /// Alternatives of conjunctions of `@include` and `@skip` conditions: the
    /// field is fetched when any alternative holds. Empty when it always is.
    public let guards: [[Guard]]
    /// The response key's bytes and a fixed key's text, taken once when the
    /// static plan is built rather than at every resolution.
    let keyBytes: [UInt8]
    let fixedStorageKey: String?
    /// Whether resolving the field reads a variable: its key, its guards, its
    /// lookup, its connection or its edit, or a field below it.
    let readsVariables: Bool

    init(responseKey: String, key: StorageKey, kind: Kind, edit: Edit?, deferred: String?, caught: Bool, guards: [[Guard]]) {
        self.responseKey = responseKey
        self.key = key
        self.kind = kind
        self.edit = edit
        self.deferred = deferred
        self.caught = caught
        self.guards = guards
        keyBytes = Array(responseKey.utf8)
        var readsVariables = !guards.isEmpty
        switch key {
        case .fixed(let slot): fixedStorageKey = Registry.storageKey(slot)
        case .dynamic: fixedStorageKey = nil; readsVariables = true
        }
        if case .variable? = edit?.connections { readsVariables = true }
        if case .linked(let selection, _, let lookup, let connection) = kind {
            if selection.readsVariables { readsVariables = true }
            if case .variable? = lookup?.key { readsVariables = true }
            if let connection, connection.readsVariables { readsVariables = true }
        }
        self.readsVariables = readsVariables
    }

    public static func scalar(_ responseKey: String, key: StorageKey, kind: ScalarKind, list: Bool, edit: Edit? = nil, deferred: String? = nil, caught: Bool = false, guards: [[Guard]] = []) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .scalar(kind, list: list), edit: edit, deferred: deferred, caught: caught, guards: guards)
    }

    public static func linked(_ responseKey: String, key: StorageKey, plural: Bool, lookup: Lookup? = nil, connection: ConnectionPlan? = nil, edit: Edit? = nil, deferred: String? = nil, caught: Bool = false, guards: [[Guard]] = [], selection: Selection) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .linked(selection, plural: plural, lookup: lookup, connection: connection), edit: edit, deferred: deferred, caught: caught, guards: guards)
    }

    /// Whether the variables select the field.
    func selected(by variables: Variables) -> Bool {
        guards.isEmpty || guards.contains { conjunction in conjunction.allSatisfy { $0.holds(variables) } }
    }
}

/// A selection set on one type. On an interface or union, the payload's
/// `__typename` names each record's concrete type, and the type picks the
/// variant: the fields that type reads.
@_spi(Generated)
public final class Selection: Sendable {
    /// The fields one group of concrete types reads.
    public struct Variant: Sendable {
        /// The concrete types the variant serves; `nil` serves every other
        /// type, or, with a condition, every type a response says satisfies
        /// it.
        public let types: [TypeID]?
        /// The interface or union whose members the variant serves, for a
        /// type the build did not list: its fields are those selected under
        /// the condition, with the ones every type reads.
        public let condition: TypeID?
        public let fields: [PlanField]

        public init(types: [TypeID]?, condition: TypeID? = nil, fields: [PlanField]) {
            self.types = types
            self.condition = condition
            self.fields = fields
        }
    }

    /// Relay's answer to a type condition in a response, `__isNamed:
    /// __typename`: the key the answer comes under, and the condition.
    public struct MembershipAnswer: Sendable {
        public let responseKey: String
        public let condition: TypeID

        public init(_ responseKey: String, _ condition: TypeID) {
            self.responseKey = responseKey
            self.condition = condition
        }
    }

    public let type: TypeID
    /// The response key of the field that keys a record of the type, `id`,
    /// or nil for a type keyed by its path. The ingest knows no field by
    /// name: it reads the key the plan says.
    public let key: String?
    public let isAbstract: Bool
    /// The membership answers the response carries, for a record of a type
    /// the build did not list.
    public let memberships: [MembershipAnswer]
    public let variants: [Variant]
    /// Whether any field below reads a variable; when none does, the
    /// selection resolves once and keeps the resolution.
    let readsVariables: Bool
    private let resolution = Mutex<ResolvedSelection?>(nil)

    /// A selection every type reads alike.
    public convenience init(type: TypeID, key: String?, abstract: Bool = false, fields: [PlanField]) {
        self.init(type: type, key: key, abstract: abstract, variants: [Variant(types: nil, fields: fields)])
    }

    public init(type: TypeID, key: String?, abstract: Bool = false, memberships: [MembershipAnswer] = [], variants: [Variant]) {
        self.type = type
        self.key = key
        isAbstract = abstract
        self.memberships = memberships
        self.variants = variants
        readsVariables = variants.contains { $0.fields.contains(where: \.readsVariables) }
    }

    /// Binds the variables: fields whose guards fail are dropped, keys with
    /// variables are rendered, and each listed type's variant is resolved
    /// now; every other type's is resolved from the shared fields when a
    /// record of it first comes.
    func resolve(_ variables: Variables, _ hold: Keys.Hold) -> ResolvedSelection {
        if readsVariables { return resolving(variables, hold) }
        if let resolved = resolution.withLock({ $0 }) { return resolved }
        let resolved = resolving(variables, hold)
        resolution.withLock { $0 = resolved }
        return resolved
    }

    private func resolving(_ variables: Variables, _ hold: Keys.Hold) -> ResolvedSelection {
        var listed: [TypeID: ResolvedVariant] = [:]
        var conditions: [(TypeID, [ResolvedField])] = []
        var others: [ResolvedField] = []
        for variant in variants {
            let fields = variant.fields.filter { $0.selected(by: variables) }.map { resolve($0, variables, hold) }
            guard let types = variant.types else {
                if let condition = variant.condition {
                    conditions.append((condition, fields))
                } else {
                    others = fields
                }
                continue
            }
            for concrete in types {
                listed[concrete] = ResolvedVariant(type: concrete, fields: fields.map { $0.on(concrete, hold) })
            }
        }
        // A selection that reads no variables renders no key, and its
        // resolution is shared by every store: it holds no store's keys.
        return ResolvedSelection(type: type, key: key, isAbstract: isAbstract, fields: others, listed: listed, conditions: conditions, memberships: memberships, hold: readsVariables ? hold : nil)
    }

    /// A field with its variables bound, its slot on the selection's own type.
    private func resolve(_ field: PlanField, _ variables: Variables, _ hold: Keys.Hold) -> ResolvedField {
        let storageKey = Selection.render(field, variables)
        let kind: ResolvedField.Kind = switch field.kind {
        case .scalar(let scalar, let list): .scalar(scalar, list: list)
        case .linked(let selection, let plural, let lookup, let connection):
            .linked(
                selection.resolve(variables, hold),
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
                        rendered: connection.key.isRendered,
                        slot: Selection.slot(connection.key, key, on: type, hold),
                        slots: connection.slots,
                        mode: Selection.mode(connection, variables)
                    )
                }
            )
        }
        return ResolvedField(
            responseKey: field.responseKey,
            keyBytes: field.keyBytes,
            storageKey: storageKey,
            rendered: field.key.isRendered,
            slot: Selection.slot(field.key, storageKey, on: type, hold),
            kind: kind,
            edit: field.edit.map { edit in
                ResolvedEdit(
                    kind: edit.kind,
                    connections: Selection.connections(edit.connections, variables),
                    edgeType: edit.edgeType
                )
            },
            deferred: field.deferred,
            caught: field.caught
        )
    }

    private static func render(_ key: StorageKey, _ variables: Variables) -> String {
        switch key {
        case .fixed(let slot): Registry.storageKey(slot)
        case .dynamic(let key): key.render(variables)
        }
    }

    private static func render(_ field: PlanField, _ variables: Variables) -> String {
        if let fixed = field.fixedStorageKey { return fixed }
        return render(field.key, variables)
    }

    private static func slot(_ key: StorageKey, _ storageKey: String, on type: TypeID, _ hold: Keys.Hold) -> Slot {
        switch key {
        case .fixed(let slot) where slot.type == type: slot
        case .fixed: Registry.slot(type, storageKey)
        case .dynamic: hold.keys.slot(type, storageKey, for: hold)
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

    /// The connection ids an edit names, from its variable or constant list.
    private static func connections(_ connections: Edit.Connections?, _ variables: Variables) -> [String] {
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
package struct LookupKey: Sendable {
    package let type: TypeID?
    package let possibleTypes: Members?
    package let value: String
}

/// A connection with its variables bound: the client key on the parent, the
/// slots, and how the page it describes joins the connection. A class, so a
/// field's kind stays one word wide and the ingest copies nothing per key.
package final class ResolvedConnection: Sendable {
    package let storageKey: String
    /// Whether the client key was rendered from variables.
    let rendered: Bool
    /// The client slot on the variant's concrete type.
    package let slot: Slot
    package let slots: ConnectionSlots
    package let mode: ConnectionMode

    init(storageKey: String, rendered: Bool, slot: Slot, slots: ConnectionSlots, mode: ConnectionMode) {
        self.storageKey = storageKey
        self.rendered = rendered
        self.slot = slot
        self.slots = slots
        self.mode = mode
    }
}

/// An edit with its connection ids bound.
package final class ResolvedEdit: Sendable {
    package let kind: Edit.Kind
    package let connections: [String]
    package let edgeType: TypeID?

    init(kind: Edit.Kind, connections: [String], edgeType: TypeID?) {
        self.kind = kind
        self.connections = connections
        self.edgeType = edgeType
    }
}

/// A plan with variables bound: per concrete type, the fields a record of
/// that type reads, with their slots on it and their keys as bytes.
package final class ResolvedSelection: Sendable {
    package let type: TypeID
    /// The response key of the field that keys a record, as the plan says.
    let key: String?
    /// Whether records of the selection are keyed by a field.
    package let hasID: Bool
    /// The key's response key as bytes, which the ingest matches without a
    /// name of its own.
    let keyBytes: [UInt8]?
    /// Whether a record's type comes from the payload's `__typename`.
    package let isAbstract: Bool
    /// The fields of a selection on an object type; on an abstract type,
    /// those every type reads, resolved on the abstract type itself for a
    /// record whose payload names no type. Stored apart from a variant so
    /// the walks over object types read it without retaining it.
    let fields: [ResolvedField]
    private let listed: [TypeID: ResolvedVariant]
    /// The fields selected under each interface or union condition, with
    /// the ones every type reads, for a type the plan did not list.
    private let conditions: [(TypeID, [ResolvedField])]
    /// Relay's membership answers the response carries, as bytes to match:
    /// a type the plan did not list takes the variants of the conditions
    /// the response says it satisfies.
    let membershipKeys: [(bytes: [UInt8], condition: TypeID)]
    /// The variants of types the plan does not list, from `base`'s fields,
    /// resolved when a record of the type first comes.
    private let others = Mutex<[Unlisted: ResolvedVariant]>([:])
    private let deferredParts = Mutex<[String: ResolvedSelection]>([:])
    /// The selection's own type's name, taken once.
    private let typeName: String
    /// The resolution's hold on the store's keys, which numbers a rendered
    /// key on a type the plan did not list when a record of it first comes,
    /// and keeps every number the resolution took while it lives; nil for a
    /// selection that reads no variables, whose resolution every store
    /// shares.
    private let hold: Keys.Hold?

    init(type: TypeID, key: String?, isAbstract: Bool, fields: [ResolvedField], listed: [TypeID: ResolvedVariant], conditions: [(TypeID, [ResolvedField])] = [], memberships: [Selection.MembershipAnswer] = [], hold: Keys.Hold?) {
        self.type = type
        self.key = key
        hasID = key != nil
        keyBytes = key.map { Array($0.utf8) }
        self.isAbstract = isAbstract
        self.fields = fields
        self.listed = listed
        self.conditions = conditions
        membershipKeys = memberships.map { (Array($0.responseKey.utf8), $0.condition) }
        self.hold = hold
        typeName = type.name
    }

    /// The fields a record of `type` reads, with their slots on it. Taken
    /// once per record; the fields are then walked without a condition.
    /// Whether the plan lists the type, so a record of it needs no answer.
    func lists(_ type: TypeID) -> Bool {
        type == self.type || listed[type] != nil
    }

    @MainActor package func variant(for type: TypeID) -> ResolvedVariant {
        if !isAbstract || type == self.type { return ResolvedVariant(type: self.type, fields: fields, typeName: typeName) }
        if let variant = listed[type] { return variant }
        return variant(forUnlisted: type) { condition in Membership.includes(type, condition) }
    }

    /// The same, where the response is read: a type the plan did not list
    /// takes the variants of the conditions the response's membership
    /// answers say it satisfies.
    func variant(for type: TypeID, memberOf answers: [TypeID]) -> ResolvedVariant {
        if !isAbstract || type == self.type { return ResolvedVariant(type: self.type, fields: fields, typeName: typeName) }
        if let variant = listed[type] { return variant }
        return variant(forUnlisted: type) { condition in answers.contains(condition) }
    }

    /// The variant of a type the plan did not list, settled once per type
    /// and per set of conditions it satisfies, so that a record met before
    /// a response answered for its type does not settle the answer: the
    /// fields every type reads, then those of each condition the type
    /// satisfies that are not among them, by response key. A linked field
    /// selected under two conditions keeps the first's children.
    private func variant(forUnlisted type: TypeID, satisfies: (TypeID) -> Bool) -> ResolvedVariant {
        var satisfied: UInt64 = 0
        for (index, (condition, _)) in conditions.enumerated() where satisfies(condition) {
            satisfied |= 1 << UInt64(min(index, 63))
        }
        let key = Unlisted(type: type, satisfied: satisfied)
        return others.withLock { cache in
            if let variant = cache[key] { return variant }
            var merged = fields
            for (index, (_, conditioned)) in conditions.enumerated() where satisfied & (1 << UInt64(min(index, 63))) != 0 {
                for field in conditioned where !merged.contains(where: { $0.responseKey == field.responseKey }) {
                    merged.append(field)
                }
            }
            let variant = ResolvedVariant(type: type, fields: merged.map { $0.on(type, hold) })
            cache[key] = variant
            return variant
        }
    }

    /// A type the plan did not list, with the conditions it satisfies as
    /// bits in the order the plan lists them.
    private struct Unlisted: Hashable {
        let type: TypeID
        let satisfied: UInt64
    }

    /// The selection an incremental part with this `@defer` label fills: the
    /// fields the label marks, on the same record. Cached per label.
    func deferred(_ label: String) -> ResolvedSelection? {
        deferredParts.withLock { cache in
            if let part = cache[label] { return part }
            func part(_ variant: ResolvedVariant) -> ResolvedVariant {
                ResolvedVariant(type: variant.type, fields: variant.fields.filter { $0.deferred == label }.map { $0.undeferred() }, typeName: variant.typeName)
            }
            let own = fields.filter { $0.deferred == label }.map { $0.undeferred() }
            let selection = ResolvedSelection(type: type, key: key, isAbstract: isAbstract, fields: own, listed: listed.mapValues(part), conditions: conditions.map { ($0.0, $0.1.filter { $0.deferred == label }.map { $0.undeferred() }) }, memberships: membershipKeys.map { Selection.MembershipAnswer(String(decoding: $0.bytes, as: UTF8.self), $0.condition) }, hold: hold)
            guard !own.isEmpty || selection.listed.values.contains(where: { !$0.fields.isEmpty }) else { return nil }
            cache[label] = selection
            return selection
        }
    }
}

/// The fields a record of one concrete type reads, with their slots on it.
package struct ResolvedVariant: Sendable {
    package let type: TypeID
    package let fields: [ResolvedField]
    /// The type's name, taken once, for the keys the ingest builds.
    let typeName: String

    init(type: TypeID, fields: [ResolvedField], typeName: String? = nil) {
        self.type = type
        self.fields = fields
        self.typeName = typeName ?? type.name
    }

    /// The field with a response key, for walking a response path.
    func field(named responseKey: String) -> Int? {
        fields.firstIndex { $0.responseKey == responseKey }
    }
}

package struct ResolvedField: Sendable {
    package enum Kind: Sendable {
        case scalar(ScalarKind, list: Bool)
        case linked(ResolvedSelection, plural: Bool, lookupKey: LookupKey?, connection: ResolvedConnection?)
    }

    package let responseKey: String
    let keyBytes: [UInt8]
    package let storageKey: String
    /// Whether the key was rendered from variables, which numbers it apart
    /// on a concrete type that has not met it.
    let rendered: Bool
    /// The slot on the variant's concrete type.
    package let slot: Slot
    package let kind: Kind
    package let edit: ResolvedEdit?
    /// The `@defer` label of the part that carries the field; the availability
    /// check does not wait for it.
    package let deferred: String?
    package let caught: Bool
    let isTypename: Bool

    init(responseKey: String, keyBytes: [UInt8], storageKey: String, rendered: Bool, slot: Slot, kind: Kind, edit: ResolvedEdit?, deferred: String?, caught: Bool) {
        self.responseKey = responseKey
        self.keyBytes = keyBytes
        self.storageKey = storageKey
        self.rendered = rendered
        self.slot = slot
        self.kind = kind
        self.edit = edit
        self.deferred = deferred
        self.caught = caught
        isTypename = responseKey == "__typename"
    }

    /// The same field as the incremental part delivers it: no longer deferred.
    func undeferred() -> ResolvedField {
        ResolvedField(responseKey: responseKey, keyBytes: keyBytes, storageKey: storageKey, rendered: rendered, slot: slot, kind: kind, edit: edit, deferred: nil, caught: caught)
    }

    /// The same field on another concrete type: its slot, and its
    /// connection's, interned there, by the store's keys when rendered.
    func on(_ type: TypeID, _ hold: Keys.Hold?) -> ResolvedField {
        if slot.type == type { return self }
        let kind: Kind = switch kind {
        case .scalar: kind
        case .linked(let child, let plural, let lookupKey, let connection):
            .linked(child, plural: plural, lookupKey: lookupKey, connection: connection.map { connection in
                ResolvedConnection(
                    storageKey: connection.storageKey,
                    rendered: connection.rendered,
                    slot: ResolvedField.slot(type, connection.storageKey, rendered: connection.rendered, hold),
                    slots: connection.slots,
                    mode: connection.mode
                )
            })
        }
        return ResolvedField(
            responseKey: responseKey,
            keyBytes: keyBytes,
            storageKey: storageKey,
            rendered: rendered,
            slot: ResolvedField.slot(type, storageKey, rendered: rendered, hold),
            kind: kind,
            edit: edit,
            deferred: deferred,
            caught: caught
        )
    }

    /// The key's slot on another type: the store's for a rendered key, which
    /// only a selection that reads variables has, and the build's otherwise.
    private static func slot(_ type: TypeID, _ storageKey: String, rendered: Bool, _ hold: Keys.Hold?) -> Slot {
        guard rendered else { return Registry.slot(type, storageKey) }
        guard let hold else { preconditionFailure("a rendered key is resolved under a selection that reads variables, which holds the store's keys") }
        return hold.keys.slot(type, storageKey, for: hold)
    }
}
