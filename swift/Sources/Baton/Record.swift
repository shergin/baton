import Observation

/// One normalized object in the store, and the observable the UI framework
/// tracks. A view body that reads a slot is invalidated when that slot of this
/// record changes, through one of sixteen invalidation channels.
@MainActor
public final class Record: Observable {
    nonisolated public let type: TypeID
    /// `Type:id` for entities with a key, a path-based client id otherwise.
    nonisolated public let key: String
    /// The id of an entity, for the store's index and for refetching by id.
    nonisolated public let entityID: String?
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
    init(type: TypeID, key: String, entityID: String? = nil) {
        self.type = type
        self.key = key
        self.entityID = entityID
        values = []
    }

    /// Makes room for the slots a batch is about to write.
    func reserve(_ count: Int) {
        values.reserveCapacity(count)
    }

    /// Reads a slot and registers the read with the current tracking scope.
    @inline(__always)
    public func read(_ slot: Slot) -> Value {
        registrar.access(self, keyPath: Record.channels[Int(slot.index) & 15])
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

    /// Writes a slot. Returns whether the value changed; observers are notified
    /// only then.
    @discardableResult
    func write(_ slot: Slot, _ value: Value) -> Bool {
        let index = Int(slot.index)
        if index >= values.count {
            values.append(contentsOf: repeatElement(.missing, count: index + 1 - values.count))
        }
        if values[index] == value { return false }
        registrar.withMutation(of: self, keyPath: Record.channels[index & 15]) {
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
        if index >= values.count {
            values.append(contentsOf: repeatElement(.missing, count: index + 1 - values.count))
        }
        let previous = values[index]
        if previous == value { return nil }
        values[index] = value
        return previous
    }

    /// Notifies observers of a slot whose value a batch has already changed.
    func notify(_ slot: Slot) {
        registrar.withMutation(of: self, keyPath: Record.channels[Int(slot.index) & 15]) {}
    }

    /// The field error stored beside a slot, registering the read.
    public func error(_ slot: Slot) -> FieldError? {
        registrar.access(self, keyPath: Record.channels[Int(slot.index) & 15])
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

    /// Notifies every observer of the record; for deletion and revival, which
    /// change what every field reads as.
    func notifyAll() {
        for channel in Record.channels {
            registrar.withMutation(of: self, keyPath: channel) {}
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
        if index >= values.count {
            values.append(contentsOf: repeatElement(.missing, count: index + 1 - values.count))
        } else {
            guard case .missing = values[index] else { return false }
        }
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

    // The channels. Each body is distinct on purpose: identical getters are
    // merged by the optimizer and their key paths then collide in the registrar.
    nonisolated var ch0: UInt8 { 0 }
    nonisolated var ch1: UInt8 { 1 }
    nonisolated var ch2: UInt8 { 2 }
    nonisolated var ch3: UInt8 { 3 }
    nonisolated var ch4: UInt8 { 4 }
    nonisolated var ch5: UInt8 { 5 }
    nonisolated var ch6: UInt8 { 6 }
    nonisolated var ch7: UInt8 { 7 }
    nonisolated var ch8: UInt8 { 8 }
    nonisolated var ch9: UInt8 { 9 }
    nonisolated var ch10: UInt8 { 10 }
    nonisolated var ch11: UInt8 { 11 }
    nonisolated var ch12: UInt8 { 12 }
    nonisolated var ch13: UInt8 { 13 }
    nonisolated var ch14: UInt8 { 14 }
    nonisolated var ch15: UInt8 { 15 }

    nonisolated(unsafe) static let channels: [KeyPath<Record, UInt8>] = [
        \.ch0, \.ch1, \.ch2, \.ch3, \.ch4, \.ch5, \.ch6, \.ch7,
        \.ch8, \.ch9, \.ch10, \.ch11, \.ch12, \.ch13, \.ch14, \.ch15,
    ]
}

/// A record's identity, for list diffing. Stable for the record's lifetime.
public struct RecordID: Hashable, Sendable {
    let identifier: ObjectIdentifier
    public let key: String

    @MainActor init(_ record: Record) {
        identifier = ObjectIdentifier(record)
        key = record.key
    }
}
