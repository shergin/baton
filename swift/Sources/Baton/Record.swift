import Observation

/// One normalized object in the store, and the observable the UI framework
/// tracks. A view body that reads a slot is invalidated when that slot of this
/// record changes, through that slot's own invalidation channel.
@MainActor
public final class Record: Observable {
    nonisolated public let type: TypeID
    /// `Type:id` for entities with a key, a path-based client id otherwise.
    nonisolated public let key: String
    /// Where the id starts inside `key`, or -1 for a record keyed by its path.
    nonisolated let idOffset: Int32
    /// Whether `@deleteRecord` removed it: links to it read as null and lists
    /// skip it, until a payload names it again.
    public private(set) var deleted = false
    /// Whether the record's row in the image has been read, so that the
    /// availability check reads it once.
    private(set) var hydrated = false
    /// Whether the collector took the record out of the store. A link that
    /// still holds it is repointed when the image is read.
    private(set) var swept = false
    private var values: ContiguousArray<Value>
    /// Field errors by slot index; allocated when the first error lands.
    private var errors: [Int32: FieldError]?
    nonisolated private let registrar = ObservationRegistrar()

    /// Values are sized by what is written, not by how many storage keys the
    /// type has: a cursor-paginated field registers a slot per page on its
    /// parent type, and records of that type must not pay for pages they
    /// never saw.
    init(type: TypeID, key: String, idOffset: Int32 = -1) {
        self.type = type
        self.key = key
        self.idOffset = idOffset
        values = []
    }

    /// Whether the record is an entity, keyed `Type:id`.
    nonisolated var isEntity: Bool { idOffset >= 0 }

    /// The id of an entity, for refetching by id; nil for a record keyed by
    /// its path.
    nonisolated public var entityID: String? {
        guard idOffset >= 0 else { return nil }
        return String(key.utf8.dropFirst(Int(idOffset)))
    }

    /// Whether the record is an entity with this id, without making a string.
    nonisolated func hasID(_ id: String) -> Bool {
        idOffset >= 0 && key.utf8.dropFirst(Int(idOffset)).elementsEqual(id.utf8)
    }

    /// Makes room for the slots a batch is about to write.
    func reserve(_ count: Int) {
        values.reserveCapacity(count)
    }

    /// Reads a slot and registers the read with the current tracking scope.
    @inline(__always)
    public func read(_ slot: Slot) -> Value {
        registrar.access(self, keyPath: Record.channel(slot.index))
        let index = Int(slot.index)
        return index < values.count ? values[index] : .missing
    }

    /// Reads without registering; for the store's own bookkeeping.
    func peek(_ slot: Slot) -> Value {
        let index = Int(slot.index)
        return index < values.count ? values[index] : .missing
    }

    /// Reads a slot by index without registering; for copying between records.
    func peek(index: Int) -> Value {
        index < values.count ? values[index] : .missing
    }

    /// How many slots hold a value or could; for copying between records.
    var slotCount: Int { values.count }

    /// Makes the values long enough to hold `index`, every new slot missing.
    @inline(__always)
    private func grow(to index: Int) {
        if index >= values.count {
            values.append(contentsOf: repeatElement(.missing, count: index + 1 - values.count))
        }
    }

    /// Writes a slot. Returns whether the value changed; observers are notified
    /// only then.
    @discardableResult
    func write(_ slot: Slot, _ value: Value) -> Bool {
        let index = Int(slot.index)
        grow(to: index)
        if values[index] == value { return false }
        registrar.withMutation(of: self, keyPath: Record.channel(Int32(index))) {
            values[index] = value
        }
        return true
    }

    /// Writes a slot without notifying. Returns the previous value when the
    /// value changed, `nil` when it was equal. Batches notify at their end.
    func writeSilently(_ slot: Slot, _ value: Value) -> Value? {
        // A slot of another type would land at an index this type uses for
        // another field.
        assert(slot.type == type, "a \(slot.type.name) slot written into a \(type.name) record")
        let index = Int(slot.index)
        grow(to: index)
        let previous = values[index]
        if previous == value { return nil }
        values[index] = value
        return previous
    }

    /// Notifies observers of a slot whose value a batch has already changed.
    func notify(_ slot: Slot) {
        registrar.withMutation(of: self, keyPath: Record.channel(slot.index)) {}
    }

    /// The field error stored beside a slot, registering the read.
    public func error(_ slot: Slot) -> FieldError? {
        registrar.access(self, keyPath: Record.channel(slot.index))
        return errors?[slot.index]
    }

    /// Whether any slot carries an error; for the commit's fast path.
    var hasErrors: Bool { errors != nil }

    /// Stores or clears a slot's error, silently. Returns whether it changed.
    func setError(_ slot: Slot, _ error: FieldError?) -> Bool {
        if let error {
            if errors == nil { errors = [:] }
            if errors?[slot.index] == error { return false }
            errors?[slot.index] = error
            return true
        }
        guard errors?.removeValue(forKey: slot.index) != nil else { return false }
        if errors?.isEmpty == true { errors = nil }
        return true
    }

    /// Notifies each slot that links to one of `targets`: a link, or a list
    /// with it among its elements. The deletion of a target changes what
    /// such a slot reads as without changing the slot.
    func notifyLinks(to targets: Set<ObjectIdentifier>) {
        // One deleted record is the common case: identities compare without
        // hashing.
        let only = targets.count == 1 ? targets.first : nil
        @inline(__always) func isTarget(_ record: Record) -> Bool {
            if let only { return ObjectIdentifier(record) == only }
            return targets.contains(ObjectIdentifier(record))
        }
        for index in values.indices {
            switch values[index] {
            case .ref(let target) where isTarget(target):
                registrar.withMutation(of: self, keyPath: Record.channel(Int32(index))) {}
            case .refs(let list) where list.contains(where: { $0.map(isTarget) ?? false }):
                registrar.withMutation(of: self, keyPath: Record.channel(Int32(index))) {}
            default:
                continue
            }
        }
    }

    /// Whether the record is of the given type: its concrete type, from the
    /// payload's `__typename` for interface- and union-typed fields.
    public func `is`(_ type: TypeID) -> Bool { self.type == type }

    /// Forgets every value, silently: the record is leaving the store, and
    /// anything still holding it reads missing data and reports it.
    func clear() {
        for index in values.indices { values[index] = .missing }
        errors = nil
        swept = true
    }

    /// The record as the image stores it: its values and errors now.
    func snapshot() -> Persistence.Snapshot {
        Persistence.Snapshot(record: self, values: values, errors: errors, deleted: deleted)
    }

    /// The field error beside a slot, without registering the read.
    func peekError(_ slot: Slot) -> FieldError? {
        errors?[slot.index]
    }

    /// Every slot that holds a value, with its error; for the store dumps
    /// under `spec/`.
    package var storedSlots: [(slot: Slot, value: Value, error: FieldError?)] {
        values.indices.compactMap { index in
            if case .missing = values[index] { return nil }
            let slot = Slot(type: type, index: Int32(index))
            return (slot, values[index], errors?[Int32(index)])
        }
    }

    /// Notes that the record's row has been read from the image.
    func setHydrated() {
        hydrated = true
    }

    /// Fills a slot the record lacks with a value read from the image, and
    /// its field error with it, silently. A slot that holds a value is left
    /// alone: memory is the truth. Returns whether the slot was filled.
    func fill(_ slot: Slot, _ value: Value, error: FieldError?) -> Bool {
        let index = Int(slot.index)
        if index < values.count {
            guard case .missing = values[index] else { return false }
        }
        grow(to: index)
        values[index] = value
        if let error {
            if errors == nil { errors = [:] }
            errors?[slot.index] = error
        }
        return true
    }

    /// Marks the record deleted or revives it; the store clears the values
    /// around it and notifies.
    func setDeleted(_ deleted: Bool) {
        self.deleted = deleted
    }

    /// Drops links to swept records, silently; used on the root.
    func prune(_ swept: Set<ObjectIdentifier>) {
        for index in values.indices {
            switch values[index] {
            case .ref(let target) where swept.contains(ObjectIdentifier(target)):
                values[index] = .missing
            case .refs(let targets) where targets.contains(where: { $0.map { swept.contains(ObjectIdentifier($0)) } ?? false }):
                values[index] = .missing
            default:
                continue
            }
        }
    }

    // The channels: one key path per slot index, through one subscript.
    // Observation tells key paths apart by the getter they reach, and the
    // optimizer merges getters with identical bodies, so no other getter of
    // the type that a key path reaches may have this body.
    nonisolated subscript(channel index: Int32) -> UInt8 { UInt8(truncatingIfNeeded: index) }

    /// The channel of each slot index, made on first use. Isolated to the
    /// main actor, so no two accesses overlap and the dynamic exclusivity
    /// check every read would pay is left out.
    @exclusivity(unchecked)
    private static var channels: ContiguousArray<KeyPath<Record, UInt8>> = []

    /// The invalidation channel of a slot: a read registers on it, and only
    /// a change of that slot notifies it.
    @inline(__always)
    static func channel(_ index: Int32) -> KeyPath<Record, UInt8> {
        let position = Int(index)
        if position < channels.count { return channels[position] }
        return makeChannels(through: position)
    }

    private static func makeChannels(through position: Int) -> KeyPath<Record, UInt8> {
        while channels.count <= position {
            channels.append(\Record.[channel: Int32(channels.count)])
        }
        return channels[position]
    }
}

/// A record's identity, for list diffing. Stable for the record's lifetime.
public struct RecordID: Hashable, Sendable {
    let identifier: ObjectIdentifier
    public let key: String

    @MainActor init(_ record: Record) {
        identifier = ObjectIdentifier(record)
        key = record.key
    }

    /// The key stays in equality: an identifier is reused once its record
    /// dies, and a list may still hold the old id.
    public static func == (lhs: RecordID, rhs: RecordID) -> Bool {
        lhs.identifier == rhs.identifier && lhs.key == rhs.key
    }

    /// Hashes the identifier alone, which tells live records apart without
    /// reading the key's bytes.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}
