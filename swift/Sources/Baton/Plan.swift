import Foundation
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
@available(*, unavailable, message: "this generated code is of format 3 and the runtime reads format 5; rebuild with the compiler of this release")
public enum Format3 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 4 and the runtime reads format 6; rebuild with the compiler of this release")
public enum Format4 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 5 and the runtime reads format 6: a read's include or skip condition is a constant the owner settles once; rebuild with the compiler of this release")
public enum Format5 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 6 and the runtime reads format 7: a record's key is the fields the configuration names, in order; rebuild with the compiler of this release")
public enum Format6 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 7 and the runtime reads format 8: a lookup's key is the list of its arguments' values; rebuild with the compiler of this release")
public enum Format7 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 8 and the runtime reads format 9: a mapped scalar converts at the read; rebuild with the compiler of this release")
public enum Format8 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 9 and the runtime reads format 10: a schema enum reads as the Swift enum generated for it; rebuild with the compiler of this release")
public enum Format9 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 10 and the runtime reads format 11: a client field is marked in the plan; rebuild with the compiler of this release")
public enum Format10 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 11 and the runtime reads format 12: what never reaches the image is marked in the plan and the registry; rebuild with the compiler of this release")
public enum Format11 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 12 and the runtime reads format 13: a variable of an input type takes the struct generated for it; rebuild with the compiler of this release")
public enum Format12 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 13 and the runtime reads format 14: an operation carries its text or its id, and says its kind; rebuild with the compiler of this release")
public enum Format13 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 14 and the runtime reads format 15: a lens no longer declares its type's name; rebuild with the compiler of this release")
public enum Format14 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 15 and the runtime reads format 16: an `@inline` fragment reads as a value, through the readers that build a plural link's values; rebuild with the compiler of this release")
public enum Format15 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 16 and the runtime reads format 17: an operation value's resolution says when no environment was injected; rebuild with the compiler of this release")
public enum Format16 {}

@_spi(Generated)
@available(*, unavailable, message: "this generated code is of format 17 and the runtime reads format 18: an optimistic response is a payload; rebuild with the compiler of this release")
public enum Format17 {}

@_spi(Generated)
public enum Format18 {}

/// An operation's normalization plan, emitted by the compiler as static data:
/// what the response contains and where each value is stored.
@_spi(Generated)
public struct Plan: Sendable {
    public let root: Selection

    /// `transient` is the module's rule set for the image, named by every
    /// plan of a module that has one, so the registry learns the rules
    /// before any plan writes a row.
    public init(root: Selection, transient: Transient? = nil) { self.root = root }

    /// Binds the variables: dynamic storage keys become slots, numbered by
    /// `keys`, the store's, lookup keys become record keys, connections learn
    /// their merge mode and handles their connection ids. One resolution
    /// serves ingest, check and read, in the store whose keys numbered it.
    package func resolve(_ variables: Variables, in keys: Keys) -> ResolvedSelection {
        keys.reconcile()
        return root.resolve(variables, keys.hold())
    }
}

/// What never reaches the image, as `baton.json` configures it: the types
/// whose records are not written, and the root fields whose cells, storage
/// keys and fetch stamps are not. Made once per module, in the shared file,
/// and told to the registry when made.
@_spi(Generated)
public final class Transient: Sendable {
    public init(types: [TypeID], fields: [(TypeID, String)]) {
        for type in types { Registry.markTransient(type) }
        for (type, field) in fields { Registry.markTransient(type, field: field) }
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
    /// compiled for the field's interface or union that one value keys.
    public let possibleTypes: Members?
    /// The arguments' values that make the key, in the order of the type's
    /// key fields; one for a lookup without a type.
    public let key: [Key]

    public init(type: TypeID?, possibleTypes: Members? = nil, key: [Key]) {
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

/// One condition `@include(if:)` or `@skip(if:)` puts on a selection: the
/// variable, and the value of it that selects. Generated code declares each
/// once, so an owner settles it once, by identity, as it does a key with
/// variables.
@_spi(Generated)
public final class Guard: Sendable {
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
    /// A client field, from a schema extension: no server is asked for it
    /// and none is waited for; a payload committed by hand writes it.
    public let client: Bool
    /// A root field `transient` names: its cell, its key and the operations
    /// selecting it never reach the image.
    public let transient: Bool
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

    init(responseKey: String, key: StorageKey, kind: Kind, edit: Edit?, deferred: String?, caught: Bool, client: Bool, transient: Bool, guards: [[Guard]]) {
        self.responseKey = responseKey
        self.key = key
        self.kind = kind
        self.edit = edit
        self.deferred = deferred
        self.caught = caught
        self.client = client
        self.transient = transient
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
            if let lookup, lookup.key.contains(where: { if case .variable = $0 { return true } else { return false } }) { readsVariables = true }
            if let connection, connection.readsVariables { readsVariables = true }
        }
        self.readsVariables = readsVariables
    }

    public static func scalar(_ responseKey: String, key: StorageKey, kind: ScalarKind, list: Bool, edit: Edit? = nil, deferred: String? = nil, caught: Bool = false, client: Bool = false, transient: Bool = false, guards: [[Guard]] = []) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .scalar(kind, list: list), edit: edit, deferred: deferred, caught: caught, client: client, transient: transient, guards: guards)
    }

    public static func linked(_ responseKey: String, key: StorageKey, plural: Bool, lookup: Lookup? = nil, connection: ConnectionPlan? = nil, edit: Edit? = nil, deferred: String? = nil, caught: Bool = false, client: Bool = false, transient: Bool = false, guards: [[Guard]] = [], selection: Selection) -> PlanField {
        PlanField(responseKey: responseKey, key: key, kind: .linked(selection, plural: plural, lookup: lookup, connection: connection), edit: edit, deferred: deferred, caught: caught, client: client, transient: transient, guards: guards)
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
        /// The key of the listed types, where it differs from the selection's;
        /// nil keys by the selection's.
        public let key: [String]?
        public let fields: [PlanField]

        public init(types: [TypeID]?, key: [String]? = nil, condition: TypeID? = nil, fields: [PlanField]) {
            self.types = types
            self.key = key
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
    /// The response keys of the fields that key a record of the type, in the
    /// order `baton.json` configures them; empty for a type keyed by its
    /// path. On an interface or union, the key its members share, which a
    /// type the build did not list is keyed by. The ingest knows no field by
    /// name: it reads the keys the plan says.
    public let key: [String]
    public let isAbstract: Bool
    /// The membership answers the response carries, for a record of a type
    /// the build did not list.
    public let memberships: [MembershipAnswer]
    public let variants: [Variant]
    /// Whether any field below reads a variable; when none does, the
    /// selection resolves once and keeps the resolution.
    let readsVariables: Bool
    /// Whether a field of the selection is a transient root field: an
    /// operation selecting one leaves no fetch stamp in the image.
    let transient: Bool
    private let resolution = Mutex<ResolvedSelection?>(nil)

    /// A selection every type reads alike.
    public convenience init(type: TypeID, key: [String], abstract: Bool = false, fields: [PlanField]) {
        self.init(type: type, key: key, abstract: abstract, variants: [Variant(types: nil, fields: fields)])
    }

    public init(type: TypeID, key: [String], abstract: Bool = false, memberships: [MembershipAnswer] = [], variants: [Variant]) {
        self.type = type
        self.key = key
        isAbstract = abstract
        self.memberships = memberships
        self.variants = variants
        readsVariables = variants.contains { $0.fields.contains(where: \.readsVariables) }
        transient = variants.contains { $0.fields.contains(where: \.transient) }
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
                listed[concrete] = ResolvedVariant(type: concrete, key: variant.key ?? key, fields: fields.map { $0.on(concrete, hold) })
            }
        }
        // A selection that reads no variables renders no key, and its
        // resolution is shared by every store: it holds no store's keys.
        return ResolvedSelection(type: type, key: key, isAbstract: isAbstract, fields: others, listed: listed, conditions: conditions, memberships: memberships, hold: readsVariables ? hold : nil, transient: transient)
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
                    let parts = lookup.key.map { part in
                        switch part {
                        case .variable(let name): variables.keyText(name)
                        case .literal(let text): text
                        }
                    }
                    return LookupKey(type: lookup.type, possibleTypes: lookup.possibleTypes, value: Record.keyValue(parts))
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
            caught: field.caught,
            client: field.client
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
