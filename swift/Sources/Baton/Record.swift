import Observation

/// One normalized object in the store, and the observable the UI framework
/// tracks. A view body that reads a slot is invalidated when that slot of this
/// record changes, through that slot's own invalidation channel.
@MainActor
@_spi(Generated)
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
    /// The collection pass that last reached the record, the store's epoch:
    /// a pass marks with a number and keeps no set.
    var mark: UInt32 = 0
    /// The values of the dense slots, by index. Isolated to the main actor,
    /// so the dynamic exclusivity check each write would pay is left out.
    @exclusivity(unchecked)
    private var values: ContiguousArray<Value>
    /// The keys numbered apart that were written to the record, as `~index`
    /// in ascending order, and their values beside them. A session renders
    /// a key per cursor and per id, each numbered for the life of the
    /// process; kept apart, it widens only the records it is written to.
    /// Isolated to the main actor, so no two accesses overlap and the
    /// dynamic exclusivity check each search would pay is left out.
    @exclusivity(unchecked)
    private var renderedIDs: ContiguousArray<Int32> = []
    @exclusivity(unchecked)
    private var renderedValues: ContiguousArray<Value> = []
    /// Field errors by slot index; allocated when the first error lands.
    private var errors: [Int32: FieldError]?
    /// The registrar a tracked read registers with, one per record, made
    /// with it: its layout is its library's, and every spelling that makes
    /// it later, an optional, a box or a flag beside it, was measured to
    /// cost a read 45 to 150 ns over the constant used where it lies.
    nonisolated private let registrar = ObservationRegistrar()

    /// Values are sized by what is written, not by how many storage keys the
    /// type has: a record makes room up to the highest dense slot written to
    /// it.
    init(type: TypeID, key: String, idOffset: Int32 = -1) {
        self.type = type
        self.key = key
        self.idOffset = idOffset
        values = []
    }

    /// Whether the record is an entity, keyed `Type:id`.
    nonisolated var isEntity: Bool { idOffset >= 0 }

    /// An entity's key, `Type:id`, built here and nowhere else, so that what
    /// names a record by a bare value, a deletion, a lookup or the image's
    /// forget, reads the value part the one way it was written.
    nonisolated static func entityKey(_ typeName: String, _ id: String) -> String {
        typeName + ":" + id
    }

    /// An entity's key from the values of its key fields in order. One value
    /// is written as it is; several are each written with their backslashes
    /// and colons escaped, `Type:a\:b:c`, so that no two value lists meet.
    /// What names a record by one bare value reaches single-field keys only.
    nonisolated static func entityKey(_ typeName: String, parts: [String]) -> String {
        entityKey(typeName, keyValue(parts))
    }

    /// The value part of an entity's key from the values of its key fields:
    /// one as it is, several escaped and joined, as `entityKey(_:parts:)`
    /// writes them; what a lookup composes from its arguments.
    nonisolated static func keyValue(_ parts: [String]) -> String {
        if parts.count == 1 { return parts[0] }
        var value = ""
        for (index, part) in parts.enumerated() {
            if index > 0 { value.append(":") }
            for scalar in part.unicodeScalars {
                if scalar == ":" || scalar == "\\" { value.unicodeScalars.append("\\") }
                value.unicodeScalars.append(scalar)
            }
        }
        return value
    }

    /// Where the id starts in an entity's key of the type.
    nonisolated static func idOffset(ofType typeName: String) -> Int32 {
        Int32(typeName.utf8.count + 1)
    }

    /// The id in an entity's key: what follows the type's name, which holds
    /// no colon.
    nonisolated static func id(ofEntityKey key: String) -> Substring {
        guard let separator = key.firstIndex(of: ":") else { return key[...] }
        return key[key.index(after: separator)...]
    }

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

    /// Makes room for the slots a batch is about to write: the dense ones up
    /// to `dense`, and `rendered` keys numbered apart, so that a new record
    /// allocates each list once.
    func reserve(dense: Int, rendered: Int) {
        if dense > 0 { values.reserveCapacity(dense) }
        if rendered > 0 {
            renderedIDs.reserveCapacity(rendered)
            renderedValues.reserveCapacity(rendered)
        }
    }

    /// Reads a slot and registers the read with the current tracking scope.
    @inline(__always)
    @_spi(Generated) public func read(_ slot: Slot) -> Value {
        registrar.access(self, keyPath: Record.channel(slot.index))
        return peek(slot)
    }

    /// Reads without registering; for the store's own bookkeeping.
    @inline(__always)
    func peek(_ slot: Slot) -> Value {
        // One comparison for a dense slot the record has room for; a key
        // numbered apart is negative and takes the call.
        let index = Int(slot.index)
        if UInt(bitPattern: index) < UInt(values.count) { return values[index] }
        if index >= 0 { return .missing }
        let position = renderedLookup(slot.index)
        return position >= 0 ? renderedValues[position] : .missing
    }

    /// Whether the slot's cell holds what a scalar field of `kind` reads:
    /// null, a value of the kind as the ingest writes one, or for a list one
    /// whose first value is. A cell the image wrote under a schema that
    /// gave the field another kind is none of these: the check takes the
    /// field as absent, so the operation fetches it and the response writes
    /// the cell again, where a lens would have read nothing from a cell the
    /// check took as present. Read in place, as `peek` reads: a value copied
    /// out would retain its payload once per cell of the walk.
    @inline(__always)
    func holds(_ slot: Slot, _ kind: ScalarKind, list: Bool) -> Bool {
        let index = Int(slot.index)
        if UInt(bitPattern: index) < UInt(values.count) { return Record.fits(values[index], kind, list: list) }
        if index >= 0 { return false }
        let position = renderedLookup(slot.index)
        return position >= 0 && Record.fits(renderedValues[position], kind, list: list)
    }

    /// Not recursive, so that it inlines: a list's elements are judged apart.
    @inline(__always)
    private static func fits(_ value: Value, _ kind: ScalarKind, list: Bool) -> Bool {
        switch value {
        case .missing, .ref, .refs:
            return false
        case .null:
            return true
        case .string:
            return !list && (kind == .string || kind == .custom)
        case .int:
            return !list && kind == .int
        case .double:
            return !list && kind == .double
        case .bool:
            return !list && kind == .bool
        case .list(let items):
            return list && Record.elementsFit(items, kind)
        }
    }

    /// Whether a list's first value that is not null is of the kind.
    private static func elementsFit(_ items: ContiguousArray<Value>, _ kind: ScalarKind) -> Bool {
        for item in items {
            switch item {
            case .null: continue
            case .string: return kind == .string || kind == .custom
            case .int: return kind == .int
            case .double: return kind == .double
            case .bool: return kind == .bool
            default: return false
            }
        }
        return true
    }

    /// Where a key numbered apart is among the record's, or -1. Out of
    /// line, so that the reads of dense slots stay small where they are
    /// inlined.
    @inline(never)
    private func renderedLookup(_ index: Int32) -> Int {
        let (position, found) = renderedPosition(index)
        return found ? position : -1
    }

    /// Where a key numbered apart is among the record's, or where it would
    /// go. The list is searched by halves, since the root holds a key per id
    /// a session looked up, and without a branch per step, whose outcome no
    /// predictor could guess.
    private func renderedPosition(_ index: Int32) -> (position: Int, found: Bool) {
        let id = ~index
        let count = renderedIDs.count
        guard count > 0 else { return (0, false) }
        // The last position whose id is at most `id`, or 0.
        var base = 0
        var length = count
        while length > 1 {
            let half = length >> 1
            base = renderedIDs[base &+ half] <= id ? base &+ half : base
            length &-= half
        }
        let found = renderedIDs[base]
        if found == id { return (base, true) }
        return (found < id ? base &+ 1 : base, false)
    }

    /// Whether the record has never been written to, nor filled from the
    /// image.
    var isEmpty: Bool { values.isEmpty && renderedIDs.isEmpty }

    /// How many keys numbered apart the record keeps an entry for; for the
    /// tests and the benchmarks.
    package var renderedKeyCount: Int { renderedIDs.count }

    /// Calls `body` with every slot that holds a value, for copying between
    /// records. `body` may write the slot it is given.
    func forEachValue(_ body: (Slot, Value) -> Void) {
        for index in values.indices {
            let value = values[index]
            if case .missing = value { continue }
            body(Slot(type: type, index: Int32(index)), value)
        }
        for position in renderedIDs.indices {
            let value = renderedValues[position]
            if case .missing = value { continue }
            body(Slot(type: type, index: ~renderedIDs[position]), value)
        }
    }

    /// Makes the values long enough to hold `index`, every new slot missing.
    @inline(__always)
    private func grow(to index: Int) {
        if index >= values.count {
            values.append(contentsOf: repeatElement(.missing, count: index + 1 - values.count))
        }
    }

    /// Writes a slot without notifying. Returns the previous value when the
    /// value changed, `nil` when it was equal. Batches notify at their end.
    func writeSilently(_ slot: Slot, _ value: Value) -> Value? {
        // A slot of another type would land at an index this type uses for
        // another field.
        assert(slot.type == type, "a \(slot.type.name) slot written into a \(type.name) record")
        if slot.index < 0 { return writeRendered(slot.index, value) }
        let index = Int(slot.index)
        grow(to: index)
        let previous = values[index]
        if previous == value { return nil }
        values[index] = value
        return previous
    }

    /// Writes a key numbered apart without notifying; the previous value
    /// when it changed. A key the record lacks is inserted in its place,
    /// which is the end for the key interned last. A record keeps an entry
    /// for a key only while it holds a value: writing missing takes the
    /// entry out, so the root does not keep a key per id a session looked
    /// up after the record it named is gone.
    private func writeRendered(_ index: Int32, _ value: Value) -> Value? {
        let (position, found) = renderedPosition(index)
        if found {
            let previous = renderedValues[position]
            if previous == value { return nil }
            if case .missing = value {
                renderedIDs.remove(at: position)
                renderedValues.remove(at: position)
            } else {
                renderedValues[position] = value
            }
            return previous
        }
        if case .missing = value { return nil }
        renderedIDs.insert(~index, at: position)
        renderedValues.insert(value, at: position)
        return .missing
    }

    /// Notifies observers of a slot whose value a batch has already changed.
    func notify(_ slot: Slot) {
        registrar.withMutation(of: self, keyPath: Record.channel(slot.index)) {}
    }

    /// The field error stored beside a slot, registering the read.
    @_spi(Generated) public func error(_ slot: Slot) -> FieldError? {
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
        @inline(__always) func links(_ value: Value) -> Bool {
            switch value {
            case .ref(let target): isTarget(target)
            case .refs(let list): list.contains(where: { $0.map(isTarget) ?? false })
            default: false
            }
        }
        for index in values.indices where links(values[index]) {
            registrar.withMutation(of: self, keyPath: Record.channel(Int32(index))) {}
        }
        for position in renderedIDs.indices where links(renderedValues[position]) {
            registrar.withMutation(of: self, keyPath: Record.channel(~renderedIDs[position])) {}
        }
    }

    /// Whether the record is of the given type: its concrete type, from the
    /// payload's `__typename` for interface- and union-typed fields.
    @_spi(Generated) public func `is`(_ type: TypeID) -> Bool { self.type == type }

    /// Forgets every value, silently: the record is leaving the store, and
    /// anything still holding it reads missing data and reports it.
    func clear() {
        for index in values.indices { values[index] = .missing }
        renderedIDs.removeAll()
        renderedValues.removeAll()
        errors = nil
        swept = true
    }

    /// The record and its values at one moment: what a commit hands the
    /// image's writer for a changed record. Taken on the main actor at the
    /// cost of an array retain; encoded off it.
    struct Snapshot: Sendable {
        let record: Record
        let values: ContiguousArray<Value>
        /// The keys numbered apart, as `~index`, and their values.
        let renderedIDs: ContiguousArray<Int32>
        let renderedValues: ContiguousArray<Value>
        let errors: [Int32: FieldError]?
        let deleted: Bool
        /// Whether the record's row had been read when the snapshot was
        /// taken, so that the values are everything the image holds of the
        /// record. The writer merges the values of a record not read into
        /// its row, rather than lose what the image held and memory never
        /// saw.
        let hydrated: Bool

        /// The rendered keys the row is written under, which the writer
        /// names when it writes: not to be freed before.
        nonisolated func renderedSlots(into slots: inout Set<Slot>) {
            for id in renderedIDs { slots.insert(Slot(type: record.type, index: ~id)) }
        }
    }

    /// The record as the image stores it: its values and errors now.
    func snapshot() -> Snapshot {
        Snapshot(record: self, values: values, renderedIDs: renderedIDs, renderedValues: renderedValues, errors: errors, deleted: deleted, hydrated: hydrated)
    }

    /// The field error beside a slot, without registering the read.
    func peekError(_ slot: Slot) -> FieldError? {
        errors?[slot.index]
    }

    /// Every slot that holds a value, with its error; for the store dumps
    /// under `spec/`.
    package var storedSlots: [(slot: Slot, value: Value, error: FieldError?)] {
        var stored: [(slot: Slot, value: Value, error: FieldError?)] = []
        forEachValue { slot, value in stored.append((slot, value, errors?[slot.index])) }
        return stored
    }

    /// Notes that the record's row has been read from the image.
    func setHydrated() {
        hydrated = true
    }

    /// Fills a slot the record lacks with a value read from the image, and
    /// its field error with it, silently. A slot that holds a value is left
    /// alone: memory is the truth. Returns whether the slot was filled.
    func fill(_ slot: Slot, _ value: Value, error: FieldError?) -> Bool {
        guard case .missing = peek(slot) else { return false }
        if slot.index < 0 {
            _ = writeRendered(slot.index, value)
        } else {
            let index = Int(slot.index)
            grow(to: index)
            values[index] = value
        }
        if let error {
            if errors == nil { errors = [:] }
            errors?[slot.index] = error
        }
        return true
    }

    /// Drops the entries under keys the store freed, which nothing can name
    /// any more, silently; for the collector.
    func drop(_ freed: Set<Slot>) {
        guard !renderedIDs.isEmpty else { return }
        var position = 0
        while position < renderedIDs.count {
            let index = ~renderedIDs[position]
            guard freed.contains(Slot(type: type, index: index)) else {
                position += 1
                continue
            }
            renderedIDs.remove(at: position)
            renderedValues.remove(at: position)
            errors?.removeValue(forKey: index)
        }
        if errors?.isEmpty == true { errors = nil }
    }

    /// The rendered keys the record holds a value under.
    func renderedSlots(into slots: inout Set<Slot>) {
        for id in renderedIDs { slots.insert(Slot(type: type, index: ~id)) }
    }

    /// Copies a slot's value and error under its twin, a second slot the
    /// store holds the same key at, silently. Returns whether there was a
    /// value to copy.
    func twin(_ slot: Slot, _ twin: Slot) -> Bool {
        let value = peek(slot)
        if case .missing = value { return false }
        _ = writeSilently(twin, value)
        if let error = errors?[slot.index] { errors?[twin.index] = error }
        return true
    }

    /// Marks the record deleted or revives it; the store clears the values
    /// around it and notifies.
    func setDeleted(_ deleted: Bool) {
        self.deleted = deleted
    }

    /// Drops links to swept records, silently; used on the roots. A dense
    /// slot reads missing afterwards; a key numbered apart leaves with its
    /// entry, since the roots would otherwise keep one per id and cursor a
    /// session rendered.
    func prune() {
        func linksSwept(_ value: Value) -> Bool {
            switch value {
            case .ref(let target): target.swept
            case .refs(let targets): targets.contains(where: { $0?.swept ?? false })
            default: false
            }
        }
        for index in values.indices where linksSwept(values[index]) {
            values[index] = .missing
        }
        for position in renderedValues.indices.reversed() where linksSwept(renderedValues[position]) {
            renderedIDs.remove(at: position)
            renderedValues.remove(at: position)
        }
    }

    // The channels: one key path per slot index, through one subscript.
    // Observation tells key paths apart by the getter they reach, and the
    // optimizer merges getters with identical bodies, so no other getter of
    // the type that a key path reaches may have this body.
    nonisolated subscript(channel index: Int32) -> UInt8 { UInt8(truncatingIfNeeded: index) }

    /// The channel of each dense slot index, and of each key numbered apart
    /// by `~index`, made on first use. Isolated to the main actor,
    /// so no two accesses overlap and the dynamic exclusivity check every
    /// read would pay is left out.
    @exclusivity(unchecked)
    private static var channels: ContiguousArray<KeyPath<Record, UInt8>> = []
    @exclusivity(unchecked)
    private static var renderedChannels: ContiguousArray<KeyPath<Record, UInt8>> = []

    /// The invalidation channel of a slot: a read registers on it, and only
    /// a change of that slot notifies it.
    @inline(__always)
    static func channel(_ index: Int32) -> KeyPath<Record, UInt8> {
        let position = Int(index)
        if UInt(bitPattern: position) < UInt(channels.count) { return channels[position] }
        return makeChannels(through: index)
    }

    /// The channel of a key numbered apart, or of a dense slot index not
    /// seen yet, made if it is new.
    @inline(never)
    private static func makeChannels(through index: Int32) -> KeyPath<Record, UInt8> {
        if index < 0, Int(~index) < renderedChannels.count { return renderedChannels[Int(~index)] }
        if index >= 0 {
            while channels.count <= Int(index) {
                channels.append(\Record.[channel: Int32(channels.count)])
            }
            return channels[Int(index)]
        }
        while renderedChannels.count <= Int(~index) {
            renderedChannels.append(\Record.[channel: ~Int32(renderedChannels.count)])
        }
        return renderedChannels[Int(~index)]
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
