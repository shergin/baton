import Foundation
import Synchronization

/// A plan resolved for one set of variables: the selections with their
/// slots, lookups, connections and edits settled, as the ingest, the check
/// and the lenses read them. See `spec/runtime.md`, section 2.

/// A bound lookup: the value part of the record key `Type:value`, composed
/// from the arguments as the ingest composes it from the key fields, or the
/// id among the possible types.
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
    /// The response keys of the fields that key a record, as the plan says.
    let key: [String]
    /// Whether a record's type comes from the payload's `__typename`.
    package let isAbstract: Bool
    /// Whether the selection reads a transient root field, so the operation
    /// leaves no fetch stamp in the image.
    package let transient: Bool
    /// The fields of a selection on an object type; on an abstract type,
    /// those every type reads, resolved on the abstract type itself for a
    /// record whose payload names no type. Stored apart from a variant so
    /// the walks over object types read it without retaining it.
    let fields: [ResolvedField]
    /// The variant of the selection's own type, made once: `fields` with
    /// the lists the walks need and the key fields marked.
    private let own: ResolvedVariant
    private let listed: [TypeID: ResolvedVariant]
    /// The fields selected under each interface or union condition, with
    /// the ones every type reads, for a type the plan did not list.
    private let conditions: [(TypeID, [ResolvedField])]
    /// Relay's membership answers the response carries, as bytes to match:
    /// a type the plan did not list takes the variants of the conditions
    /// the response says it satisfies.
    let membershipKeys: [(bytes: [UInt8], condition: TypeID)]
    /// The names of the types the plan lists, as bytes to match a
    /// `__typename` against, so an object of a listed type takes its type
    /// without a string and without the registry's lock; an unlisted name
    /// still asks the registry.
    let typeNameKeys: [(bytes: [UInt8], type: TypeID)]
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

    init(type: TypeID, key: [String], isAbstract: Bool, fields: [ResolvedField], listed: [TypeID: ResolvedVariant], conditions: [(TypeID, [ResolvedField])] = [], memberships: [Selection.MembershipAnswer] = [], hold: Keys.Hold?, transient: Bool = false) {
        self.type = type
        self.key = key
        self.isAbstract = isAbstract
        self.transient = transient
        self.fields = fields
        own = ResolvedVariant(type: type, key: key, fields: fields, typeName: type.name)
        self.listed = listed
        self.conditions = conditions
        membershipKeys = memberships.map { (Array($0.responseKey.utf8), $0.condition) }
        self.hold = hold
        typeName = type.name
        typeNameKeys = ([type] + listed.keys.sorted { $0.raw < $1.raw }).map { (Array($0.name.utf8), $0) }
    }

    /// The fields a record of `type` reads, with their slots on it. Taken
    /// once per record; the fields are then walked without a condition.
    /// Whether the plan lists the type, so a record of it needs no answer.
    func lists(_ type: TypeID) -> Bool {
        type == self.type || listed[type] != nil
    }

    /// The listed type whose name the bytes spell, matched without making a
    /// string; nil for an escaped name or one the plan does not list.
    func listedType(base: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ escaped: Bool) -> TypeID? {
        guard !escaped else { return nil }
        let length = end - start
        for (bytes, type) in typeNameKeys where bytes.count == length {
            if bytes.withUnsafeBufferPointer({ memcmp(base + start, $0.baseAddress!, length) == 0 }) { return type }
        }
        return nil
    }

    @MainActor package func variant(for type: TypeID) -> ResolvedVariant {
        if !isAbstract || type == self.type { return own }
        if let variant = listed[type] { return variant }
        return variant(forUnlisted: type) { condition in Membership.includes(type, condition) }
    }

    /// The same, where the response is read: a type the plan did not list
    /// takes the variants of the conditions the response's membership
    /// answers say it satisfies.
    func variant(for type: TypeID, memberOf answers: [TypeID]) -> ResolvedVariant {
        if !isAbstract || type == self.type { return own }
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
            let variant = ResolvedVariant(type: type, key: self.key, fields: merged.map { $0.on(type, hold) })
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
                ResolvedVariant(type: variant.type, key: variant.key, fields: variant.fields.filter { $0.deferred == label }.map { $0.undeferred() }, typeName: variant.typeName)
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
/// A reference, made once per type at the resolution: the walks over
/// records look it up per record, and a value of ten lists would retain
/// each of them at every lookup.
package final class ResolvedVariant: Sendable {
    package let type: TypeID
    package let fields: [ResolvedField]
    /// The type's name, taken once, for the keys the ingest builds.
    let typeName: String
    /// The response keys of the fields that key a record of the type, in
    /// order; empty for a type keyed by its path.
    let key: [String]
    /// The same as bytes, which the ingest matches without a name of its
    /// own; the fields in `read` that are among them carry their index.
    let keys: [[UInt8]]
    /// The lists the walks need, made once here, so that no walk tests a
    /// field for what it is.
    /// The fields a response is read by: every field but `__typename`, which
    /// the ingest reads as the record's identity before any field.
    let read: [ResolvedField]
    /// Where in `read` the fields are that a complete response carries: the
    /// server's own, outside any deferred part.
    let expected: [Int]
    /// The fields the availability check waits for: the server's own,
    /// outside any deferred part.
    let waits: [ResolvedField]
    /// The connections' client links, which the check walks for their
    /// merged pages after the fields, and the collector follows.
    let clientLinks: [ResolvedField]
    /// The links the collector follows: every linked field, deferred or not,
    /// and the client links.
    let follows: [ResolvedField]
    /// The client fields, which a payload committed by hand writes: the
    /// check hydrates them from the image and waits for none.
    let payloadFields: [ResolvedField]

    init(type: TypeID, key: [String], fields: [ResolvedField], typeName: String? = nil) {
        self.type = type
        self.typeName = typeName ?? type.name
        self.key = key
        keys = key.map { Array($0.utf8) }
        var marked = fields
        for (index, name) in key.enumerated() {
            guard let position = marked.firstIndex(where: { $0.responseKey == name && $0.deferred == nil }) else { continue }
            marked[position].keyIndex = Int32(index)
        }
        self.fields = marked
        let read = marked.filter { !$0.isTypename }
        self.read = read
        expected = read.indices.filter { read[$0].origin.isServer }
        waits = read.filter { $0.origin.isServer }
        payloadFields = read.filter { $0.origin == .client }
        var clientLinks: [ResolvedField] = []
        var follows: [ResolvedField] = []
        for field in read {
            guard case .linked(let child, _, _, let connection) = field.kind else { continue }
            follows.append(field)
            if let connection {
                let link = ResolvedField(responseKey: connection.storageKey, keyBytes: [], storageKey: connection.storageKey, rendered: connection.rendered, slot: connection.slot, kind: .linked(child, plural: false, lookupKey: nil, connection: nil), edit: nil, deferred: nil, caught: field.caught, client: true)
                clientLinks.append(link)
                follows.append(link)
            }
        }
        self.clientLinks = clientLinks
        self.follows = follows
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
    /// Where the field's value comes from: the server's response, the part
    /// of it under a `@defer` label, which the availability check does not
    /// wait for, or the client, which no response carries.
    package let origin: Origin
    package let caught: Bool
    let isTypename: Bool

    package enum Origin: Sendable, Equatable {
        case server
        case deferred(String)
        case client

        var isServer: Bool {
            if case .server = self { return true }
            return false
        }
    }

    /// The `@defer` label of the part that carries the field, when one does.
    package var deferred: String? {
        if case .deferred(let label) = origin { return label }
        return nil
    }

    /// Which of the record's key fields this is, or -1: set by the variant
    /// the field is read in, since a field keys one type and not another.
    var keyIndex: Int32 = -1

    init(responseKey: String, keyBytes: [UInt8], storageKey: String, rendered: Bool, slot: Slot, kind: Kind, edit: ResolvedEdit?, deferred: String?, caught: Bool, client: Bool = false) {
        self.responseKey = responseKey
        self.keyBytes = keyBytes
        self.storageKey = storageKey
        self.rendered = rendered
        self.slot = slot
        self.kind = kind
        self.edit = edit
        origin = client ? .client : deferred.map(Origin.deferred) ?? .server
        self.caught = caught
        isTypename = responseKey == "__typename"
    }

    /// The same field as the incremental part delivers it: no longer deferred.
    func undeferred() -> ResolvedField {
        ResolvedField(responseKey: responseKey, keyBytes: keyBytes, storageKey: storageKey, rendered: rendered, slot: slot, kind: kind, edit: edit, deferred: nil, caught: caught, client: origin == .client)
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
            caught: caught,
            client: origin == .client
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
