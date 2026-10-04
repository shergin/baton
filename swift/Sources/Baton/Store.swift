import Foundation
import Observation

/// The normalized records, on the main actor. Reads are synchronous; commits
/// are atomic batches that notify only the observed fields that changed.
/// Optimistic layers sit on top of the server's truth and rebase under it.
@MainActor
public final class Store {
    nonisolated package static let rootKey = "client:root"
    nonisolated package static let mutationRootKey = "client:root:mutation"
    nonisolated package static let subscriptionRootKey = "client:root:subscription"

    /// The record query root fields hang off. The three roots are typed
    /// `Query`, `Mutation` and `Subscription` whatever the schema calls its
    /// root types; the compiler interns those types by these names.
    package let root: Record
    /// The record mutation payloads hang off; their entities merge as usual.
    package let mutationRoot: Record
    /// The record subscription payloads hang off.
    package let subscriptionRoot: Record
    private var records: [String: Record] = [:]
    /// The environment that owns the store, for lenses that fetch.
    weak var environment: Environment?

    /// Called when a lens reads a slot the store never received. Debug builds
    /// print by default; a product can route it to its own reporting.
    public var reportMissing: ((Record, Slot) -> Void)?

    /// Called when a lens reads a value its generated type cannot hold: a
    /// null in a field typed non-null, or a value of another kind than the
    /// field's. The read returns the type's zero value, or nil. Debug builds
    /// print by default.
    public var reportUnexpected: ((Record, Slot, Value) -> Void)?

    /// The stand-in a non-null link without a record reads, one per type and
    /// never in `records`: its fields are all missing, and the anchor over it
    /// has no store, so a lens below reads zero values and reports nothing a
    /// second time.
    private var placeholders: [TypeID: Record] = [:]

    /// Called when a bare id names live records of more than one type, so
    /// `@deleteRecord` or a lookup without a type cannot tell which: the id
    /// and the records. Nothing is deleted or resolved. Debug builds print
    /// by default.
    public var reportAmbiguousIdentity: ((String, [Record]) -> Void)?

    /// Bumped by `invalidate()`; handles fetched before it are stale.
    package private(set) var invalidationEpoch = 0

    /// Optimistic responses currently applied, oldest first.
    package private(set) var optimisticLayers: [OptimisticLayer] = []

    /// The store's image on disk, when it has one: every commit is written
    /// behind, and the availability check reads from it what memory lacks.
    public let persistence: Persistence?
    /// How many records have been filled from the image; for tests and
    /// benchmarks.
    package internal(set) var hydratedRecords = 0
    /// Whether the walk in memory met a record or a root field the image
    /// filled.
    private var metHydrated = false
    /// The root's fields the image filled, by slot index. The image stores
    /// the root a row per field and the root is never marked hydrated, so
    /// these tell the walk in memory which of its fields came from there.
    var hydratedRootSlots: Set<Int32> = []
    /// The image's connection while a check is reading from it.
    private var reading: Disk?
    /// Whether the batch in progress changed a field error, a null, a link,
    /// or whether a record is deleted: what `@throwOnFieldError` and
    /// bubbling `@required` read.
    private var nullsOrErrorsChanged = false

    public init(persistence: Persistence? = nil) {
        self.persistence = persistence
        root = Record(type: Registry.type("Query"), key: Store.rootKey)
        mutationRoot = Record(type: Registry.type("Mutation"), key: Store.mutationRootKey)
        subscriptionRoot = Record(type: Registry.type("Subscription"), key: Store.subscriptionRootKey)
        records[Store.rootKey] = root
        records[Store.mutationRootKey] = mutationRoot
        records[Store.subscriptionRootKey] = subscriptionRoot
        #if DEBUG
        reportMissing = { record, slot in
            print("Baton: missing data: \(record.key).\(slot.storageKey) was read but never fetched; the miss was recorded")
        }
        reportUnexpected = { record, slot, value in
            print("Baton: \(record.key).\(slot.storageKey) holds \(value), which its reader's type cannot hold; it read as a zero value or nil")
        }
        reportAmbiguousIdentity = { id, records in
            print("Baton: the id \(id) names \(records.map(\.key).joined(separator: ", ")); nothing was done for it")
        }
        #endif
    }

    /// Marks everything fetched so far as stale, in memory and in the image;
    /// `Environment.invalidate()` is the public way, which also refetches.
    func invalidate() {
        invalidationEpoch += 1
        persistence?.invalidate()
    }

    /// The placeholder record of a type.
    func placeholder(_ type: TypeID) -> Record {
        if let record = placeholders[type] { return record }
        let record = Record(type: type, key: "client:placeholder:" + type.name)
        placeholders[type] = record
        return record
    }

    package var count: Int { records.count }

    package func existing(_ key: String) -> Record? { records[key] }

    /// Every record the store holds, by key; for the store dumps under `spec/`.
    package var recordsByKey: [String: Record] { records }

    /// The record for a key, created on first sight.
    func record(key: String, type: TypeID, entity: Bool) -> Record {
        record(key: key, type: type, entity: entity).record
    }

    /// The record for a key, and whether this call created it.
    private func record(key: String, type: TypeID, entity: Bool) -> (record: Record, created: Bool) {
        if let record = records[key] {
            // A key names one type: an entity's starts with it, and a path
            // key under an interface or union ends with it.
            assert(record.type == type, "\(key) is a \(record.type.name), not a \(type.name)")
            return (record, false)
        }
        let record = Record(type: type, key: key, idOffset: entity ? Int32(type.name.utf8.count + 1) : -1)
        records[key] = record
        return (record, true)
    }

    /// The record a stored link names: the one the store holds, deleted or
    /// not, or a new empty one for the image to fill.
    func target(key: String, type: TypeID, entity: Bool) -> Record {
        if let record = records[key] { return record }
        return record(key: key, type: type, entity: entity)
    }

    // MARK: Commits and optimistic layers

    /// A pending optimistic response: its change set, and what it overwrote.
    package struct OptimisticLayer: Identifiable, Sendable {
        package let id: UUID
        package let changes: ChangeSet
        var undo: [Undo] = []
    }

    /// One step of a batch, as it was before the batch: reversed when a
    /// layer lifts, and read for what the image is told.
    enum Undo: Sendable {
        case slot(Record, Slot, Value)
        case error(Record, Slot, FieldError?)
        case deletion(Record, was: Bool)
    }

    /// A slot of one record, for sets of slots.
    private struct SlotKey: Hashable {
        let record: ObjectIdentifier
        let slot: Slot
    }

    /// Tracks every slot a batch touched, with its value and its error
    /// before the batch, and every record whose deleted flag it changed, with
    /// the flag before the batch, so the batch notifies only what differs at
    /// the end.
    @MainActor
    private struct Transaction {
        /// A plain commit with no layers notifies as it writes; nothing can
        /// change back within the batch, so there is nothing to net out.
        private let direct: Bool
        private var directCount = 0
        private var originals: [SlotKey: Original] = [:]
        private var flags: [ObjectIdentifier: (record: Record, was: Bool)] = [:]

        private struct Original {
            let record: Record
            let slot: Slot
            let value: Value
            let error: FieldError?
        }

        init(direct: Bool = false) {
            self.direct = direct
        }

        /// Notes a slot about to change, with what it held before.
        mutating func touched(_ record: Record, _ slot: Slot, value: Value, error: FieldError?) {
            if direct {
                record.notify(slot)
                directCount += 1
                return
            }
            let key = SlotKey(record: ObjectIdentifier(record), slot: slot)
            if originals[key] == nil { originals[key] = Original(record: record, slot: slot, value: value, error: error) }
        }

        /// Notes a record whose deleted flag is about to change, with the flag
        /// before.
        mutating func flagged(_ record: Record, was: Bool) {
            let key = ObjectIdentifier(record)
            if flags[key] == nil { flags[key] = (record, was) }
        }

        /// The records whose deleted flag differs at the end.
        var flipped: [Record] {
            flags.values.filter { $0.record.deleted != $0.was }.map(\.record)
        }

        /// Notifies changed slots; returns how many changed.
        func finish() -> Int {
            if direct { return directCount }
            var changed = 0
            for original in originals.values
            where original.record.peek(original.slot) != original.value || original.record.peekError(original.slot) != original.error {
                original.record.notify(original.slot)
                changed += 1
            }
            return changed
        }
    }

    /// Ends a batch: notifies the slots that changed, and when the batch
    /// changed whether records are deleted, every slot that links to one of
    /// them, since a link to a deleted record reads as null and a list skips
    /// it. Returns how many slots changed.
    private func finish(_ transaction: Transaction) -> Int {
        let changed = transaction.finish()
        let flipped = transaction.flipped
        if !flipped.isEmpty {
            let targets = Set(flipped.map(ObjectIdentifier.init))
            for record in records.values { record.notifyLinks(to: targets) }
        }
        return changed
    }

    /// Applies a change set from the server. Under optimistic layers, the
    /// layers are lifted, the payload applied, and the layers re-applied, and
    /// only the net difference is notified. Returns the number of slots that
    /// changed.
    @discardableResult
    package func commit(_ changes: ChangeSet) -> Int {
        defer { reevaluateIfNeeded() }
        if optimisticLayers.isEmpty {
            var transaction = Transaction(direct: true)
            applyServer(changes, into: &transaction)
            return finish(transaction)
        }
        var transaction = Transaction()
        revertLayers(from: 0, into: &transaction)
        applyServer(changes, into: &transaction)
        reapplyLayers(from: 0, into: &transaction)
        return finish(transaction)
    }

    /// Lets the environment settle the phases that read errors and nulls,
    /// once the batch that changed one has notified.
    private func reevaluateIfNeeded() {
        guard nullsOrErrorsChanged else { return }
        nullsOrErrorsChanged = false
        environment?.reevaluate()
    }

    /// Applies a server's payload and hands the image what it changed, and
    /// what it could not change in memory, for the image to forget.
    private func applyServer(_ changes: ChangeSet, into transaction: inout Transaction) {
        // Without an image an edit memory cannot make is simply not made.
        forgets = persistence == nil ? nil : Forgets()
        let undo = apply(changes, into: &transaction)
        if let forgets, !forgets.keys.isEmpty || !forgets.ids.isEmpty {
            persistence?.forget(keys: forgets.keys, ids: forgets.ids)
            forgottenKeys.formUnion(forgets.keys)
            forgottenIDs.formUnion(forgets.ids)
            // A record with the id that an earlier payload wrote is forgotten
            // with the rest.
            if !forgets.ids.isEmpty, !rewrittenKeys.isEmpty {
                rewrittenKeys = rewrittenKeys.filter { !forgets.ids.contains(Store.id(ofEntity: $0)) }
            }
        }
        forgets = nil
        // A record the payload wrote is the store's again, by its exact key.
        // The other records with a forgotten id stay unread until the writer
        // has dropped them: a payload with `Location:1` says nothing of
        // `Character:1`.
        if !forgottenKeys.isEmpty || !forgottenIDs.isEmpty {
            for index in changes.recordKeys.indices {
                let key = changes.recordKeys[index]
                forgottenKeys.remove(key)
                if !forgottenIDs.isEmpty, changes.recordIsEntity[index], forgottenIDs.contains(Store.id(ofEntity: key)) {
                    rewrittenKeys.insert(key)
                }
            }
        }
        persist(undo)
    }

    /// The id inside an entity's key: what follows its type's name, which
    /// holds no colon.
    private static func id(ofEntity key: String) -> String {
        guard let separator = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: separator)...])
    }

    /// What a server batch could not edit in memory: connection keys, and
    /// the bare ids of records `@deleteRecord` named that memory does not
    /// hold. Recorded only while a server's payload applies.
    private struct Forgets {
        var keys: [String] = []
        var ids: [String] = []
    }

    private var forgets: Forgets?

    /// What the image was told to forget, until the writer has: by key,
    /// until a response writes that key, and by bare id, but for the keys
    /// with the id that a response has written since.
    private var forgottenKeys: Set<String> = []
    private var forgottenIDs: Set<String> = []
    private var rewrittenKeys: Set<String> = []

    /// Whether the image's row of a record is not to be read. Once no forget
    /// waits for the writer, the rows are gone and the sets are emptied.
    func forgotten(_ record: Record) -> Bool {
        if forgottenKeys.isEmpty, forgottenIDs.isEmpty { return false }
        guard persistence?.forgetting == true else {
            forgottenKeys.removeAll()
            forgottenIDs.removeAll()
            rewrittenKeys.removeAll()
            return false
        }
        if forgottenKeys.contains(record.key) { return true }
        if let id = record.entityID, forgottenIDs.contains(id), !rewrittenKeys.contains(record.key) { return true }
        return false
    }

    /// Hands the image what a server's payload changed: a snapshot of every
    /// changed record, and the changed fields of the root one by one. Called
    /// while the optimistic layers are lifted, so the values are the server's.
    private func persist(_ undo: [Undo]) {
        guard let persistence, !undo.isEmpty else { return }
        var records: [Persistence.Snapshot] = []
        var fields: [Persistence.RootField] = []
        var seen = Set<ObjectIdentifier>()
        var previous: Record?
        func add(_ record: Record) {
            // A commit writes a record's slots in a run, so most repeats are
            // caught by the record before; the set catches the rest.
            if record === previous || record === mutationRoot || record === subscriptionRoot { return }
            previous = record
            if seen.insert(ObjectIdentifier(record)).inserted { records.append(record.snapshot()) }
        }
        for step in undo {
            switch step {
            case .slot(let record, let slot, _), .error(let record, let slot, _):
                if record === root {
                    fields.append(Persistence.RootField(slot: slot, value: root.peek(slot), error: root.peekError(slot)))
                } else {
                    add(record)
                }
            case .deletion(let record, _):
                add(record)
            }
        }
        if records.isEmpty, fields.isEmpty { return }
        persistence.committed(records, root: fields)
    }

    /// Applies an optimistic response on top of everything else.
    package func applyOptimistic(_ changes: ChangeSet) -> UUID {
        defer { reevaluateIfNeeded() }
        var transaction = Transaction()
        var layer = OptimisticLayer(id: UUID(), changes: changes)
        layer.undo = apply(changes, into: &transaction)
        optimisticLayers.append(layer)
        _ = finish(transaction)
        return layer.id
    }

    /// Removes an optimistic layer; later layers are re-applied over the gap.
    package func revertOptimistic(_ id: UUID) {
        guard let index = optimisticLayers.firstIndex(where: { $0.id == id }) else { return }
        defer { reevaluateIfNeeded() }
        var transaction = Transaction()
        revertLayers(from: index, into: &transaction)
        optimisticLayers.remove(at: index)
        reapplyLayers(from: index, into: &transaction)
        _ = finish(transaction)
    }

    /// Commits the server's answer to an optimistic mutation: the layer is
    /// replaced by the payload in one batch.
    @discardableResult
    package func commit(_ changes: ChangeSet, replacingOptimistic id: UUID) -> Int {
        defer { reevaluateIfNeeded() }
        var transaction = Transaction()
        revertLayers(from: 0, into: &transaction)
        optimisticLayers.removeAll { $0.id == id }
        applyServer(changes, into: &transaction)
        reapplyLayers(from: 0, into: &transaction)
        return finish(transaction)
    }

    private func revertLayers(from index: Int, into transaction: inout Transaction) {
        for layer in optimisticLayers[index...].reversed() {
            for undo in layer.undo.reversed() {
                switch undo {
                case .slot(let record, let slot, let value):
                    let error = record.peekError(slot)
                    if let previous = record.writeSilently(slot, value) {
                        transaction.touched(record, slot, value: previous, error: error)
                        noteNulls(previous, value)
                    }
                case .error(let record, let slot, let error):
                    var ignored: [Undo] = []
                    setError(record, slot, error, &transaction, &ignored)
                case .deletion(let record, let was):
                    var ignored: [Undo] = []
                    setDeleted(record, was, &transaction, &ignored)
                }
            }
        }
        for position in index..<optimisticLayers.count {
            optimisticLayers[position].undo.removeAll()
        }
    }

    private func reapplyLayers(from index: Int, into transaction: inout Transaction) {
        // An optimistic response is never written to the image: its undo
        // log stays with the layer.
        for position in index..<optimisticLayers.count {
            optimisticLayers[position].undo = apply(optimisticLayers[position].changes, into: &transaction)
        }
    }

    /// Writes one slot inside a batch: silently, recorded for the net
    /// notification and for the undo log.
    private func set(_ record: Record, _ slot: Slot, _ value: Value, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        let error = record.peekError(slot)
        if let previous = record.writeSilently(slot, value) {
            transaction.touched(record, slot, value: previous, error: error)
            undo.append(.slot(record, slot, previous))
            noteNulls(previous, value)
        }
    }

    /// Sets or clears a slot's field error inside a batch, recorded for the
    /// net notification and for the undo log.
    private func setError(_ record: Record, _ slot: Slot, _ error: FieldError?, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        let previous = record.peekError(slot)
        guard record.setError(slot, error) else { return }
        transaction.touched(record, slot, value: record.peek(slot), error: previous)
        undo.append(.error(record, slot, previous))
        nullsOrErrorsChanged = true
    }

    /// Marks a record deleted or revives it inside a batch, recorded for the
    /// holders' notification and for the undo log.
    private func setDeleted(_ record: Record, _ deleted: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard record.deleted != deleted else { return }
        transaction.flagged(record, was: record.deleted)
        undo.append(.deletion(record, was: record.deleted))
        record.setDeleted(deleted)
        nullsOrErrorsChanged = true
    }

    /// Notes for the batch a write to or from null, or a link that moved.
    @inline(__always)
    private func noteNulls(_ previous: Value, _ value: Value) {
        switch (previous, value) {
        case (.null, _), (_, .null):
            nullsOrErrorsChanged = true
        // A link moved onto another record brings that record's errors and
        // nulls into every selection that reads through it.
        case (.ref(let old), .ref(let new)) where old !== new:
            nullsOrErrorsChanged = true
        case (.refs, .refs):
            nullsOrErrorsChanged = true
        default:
            return
        }
    }

    /// Whether a stored list of links holds the records the change set's
    /// list names, in order.
    private static func same(_ existing: ContiguousArray<Record?>, _ changes: ChangeSet, _ start: Int32, _ count: Int32, _ objects: ContiguousArray<Record>) -> Bool {
        guard existing.count == Int(count) else { return false }
        for offset in 0..<Int(count) {
            let target = changes.refs[Int(start) + offset]
            if target < 0 {
                if existing[offset] != nil { return false }
            } else if existing[offset] !== objects[Int(target)] {
                return false
            }
        }
        return true
    }

    /// Whether a stored list of scalars holds the values the change set's
    /// list gives, in order.
    private static func same(_ existing: ContiguousArray<Value>, _ changes: ChangeSet, _ start: Int32, _ count: Int32) -> Bool {
        guard existing.count == Int(count) else { return false }
        for offset in 0..<Int(count) {
            switch (changes.scalars[Int(start) + offset], existing[offset]) {
            case (.null, .null): continue
            case (.bool(let new), .bool(let old)) where new == old: continue
            case (.int(let new), .int(let old)) where new == old: continue
            case (.double(let new), .double(let old)) where new == old: continue
            case (.string(let from, let to, let escaped), .string(let old)) where changes.stringEquals(from, to, escaped: escaped, old): continue
            default: return false
            }
        }
        return true
    }

    /// Writes a change set silently: last entry wins per (record, slot); a
    /// value equal to the slot's current value is neither allocated nor
    /// recorded. The edits follow: connection pages merge, edges insert,
    /// records delete. Returns the undo log of what changed.
    private func apply(_ changes: ChangeSet, into transaction: inout Transaction) -> [Undo] {
        var objects = ContiguousArray<Record>()
        objects.reserveCapacity(changes.recordKeys.count)
        var created = [Bool](repeating: false, count: changes.recordKeys.count)
        for index in 0..<changes.recordKeys.count {
            let found = record(key: changes.recordKeys[index], type: changes.recordTypes[index], entity: changes.recordIsEntity[index]) as (record: Record, created: Bool)
            objects.append(found.record)
            created[index] = found.created
        }

        // Slots this change set carries an error for keep it below rather
        // than clearing it here and setting it again.
        var erroring = Set<SlotKey>()
        for entry in changes.fieldErrors {
            erroring.insert(SlotKey(record: ObjectIdentifier(objects[Int(entry.record)]), slot: entry.slot))
        }

        var undo: [Undo] = []
        for index in 0..<objects.count {
            let record = objects[index]
            // A deleted record a payload names again comes back.
            if record.deleted { setDeleted(record, false, &transaction, &undo) }
            let range = Int(changes.starts[index])..<Int(changes.starts[index + 1])
            if created[index], !range.isEmpty {
                // A new record makes room once, for the highest dense slot it
                // receives.
                var highest: Int32 = 0
                for position in range where changes.entries[position].slot.index > highest {
                    highest = changes.entries[position].slot.index
                }
                record.reserve(Int(highest) + 1)
            }
            for position in range {
                let entry = changes.entries[position]
                // A field the payload answers without an error has none, whether
                // or not its value changed.
                if record.hasErrors, record.peekError(entry.slot) != nil,
                   erroring.isEmpty || !erroring.contains(SlotKey(record: ObjectIdentifier(record), slot: entry.slot)) {
                    setError(record, entry.slot, nil, &transaction, &undo)
                }
                let value: Value
                switch entry.value {
                case .null: value = .null
                case .bool(let bool): value = .bool(bool)
                case .int(let int): value = .int(int)
                case .double(let double): value = .double(double)
                case .string(let start, let end, let escaped):
                    if case .string(let existing) = record.peek(entry.slot), changes.stringEquals(start, end, escaped: escaped, existing) {
                        continue
                    }
                    value = .string(changes.string(start, end, escaped: escaped))
                case .ref(let target): value = .ref(objects[Int(target)])
                case .refs(let start, let count):
                    // An unchanged list is compared where it is, not built.
                    if case .refs(let existing) = record.peek(entry.slot), Store.same(existing, changes, start, count, objects) {
                        continue
                    }
                    var list = ContiguousArray<Record?>()
                    list.reserveCapacity(Int(count))
                    for offset in 0..<Int(count) {
                        let target = changes.refs[Int(start) + offset]
                        list.append(target < 0 ? nil : objects[Int(target)])
                    }
                    value = .refs(list)
                case .list(let start, let count):
                    if case .list(let existing) = record.peek(entry.slot), Store.same(existing, changes, start, count) {
                        continue
                    }
                    var list = ContiguousArray<Value>()
                    list.reserveCapacity(Int(count))
                    for offset in 0..<Int(count) {
                        switch changes.scalars[Int(start) + offset] {
                        case .null: list.append(.null)
                        case .bool(let bool): list.append(.bool(bool))
                        case .int(let int): list.append(.int(int))
                        case .double(let double): list.append(.double(double))
                        case .string(let start, let end, let escaped): list.append(.string(changes.string(start, end, escaped: escaped)))
                        default: list.append(.null)
                        }
                    }
                    value = .list(list)
                }
                if created[index] {
                    // Nobody can have read a record this batch created.
                    if let previous = record.writeSilently(entry.slot, value) {
                        undo.append(.slot(record, entry.slot, previous))
                        noteNulls(previous, value)
                    }
                } else {
                    set(record, entry.slot, value, &transaction, &undo)
                }
            }
        }

        for edit in changes.edits {
            switch edit {
            case .merge(let connection, let page, let slots, let mode):
                merge(objects[Int(connection)], page: objects[Int(page)], slots: slots, mode: mode, &transaction, &undo)
            case .insertEdge(let edge, let connections, let prepend):
                for key in connections {
                    insert(edge: objects[Int(edge)], into: key, prepend: prepend, &transaction, &undo)
                }
            case .insertNode(let node, let edgeType, let connections, let prepend):
                for key in connections {
                    insert(node: objects[Int(node)], edgeType: edgeType, into: key, prepend: prepend, &transaction, &undo)
                }
            case .deleteEdge(let id, let connections):
                for key in connections {
                    deleteEdges(of: id, from: key, &transaction, &undo)
                }
            case .deleteRecord(let id):
                // The directive names a bare id; the record is the one live
                // entity of any type with it. One memory does not hold may
                // be in the image, which forgets every record with the id.
                let found = live(id: id, among: Registry.typeNames())
                switch found.count {
                case 0: forgets?.ids.append(id)
                case 1: delete(found[0], &transaction, &undo)
                default: reportAmbiguousIdentity?(id, found)
                }
            }
        }

        // Field errors land beside the field; an error arriving counts as a
        // change of the slot.
        for entry in changes.fieldErrors {
            setError(objects[Int(entry.record)], entry.slot, entry.error, &transaction, &undo)
        }
        return undo
    }

    // MARK: Connections

    /// The connection an edit may change: in memory, live, and holding what
    /// the image has or more. One the store holds only as an empty record a
    /// link made, or not at all, would be written back with the edit alone
    /// or keep its old edges in the image: the image forgets it instead, so
    /// the next read fetches it.
    private func editable(_ key: String) -> Record? {
        if let connection = records[key], !connection.deleted, connection.hydrated || !connection.isEmpty {
            return connection
        }
        forgets?.keys.append(key)
        return nil
    }

    private static func edges(_ record: Record, _ slot: Slot) -> ContiguousArray<Record?> {
        if case .refs(let edges) = record.peek(slot) { return edges }
        return []
    }

    private static func node(of edge: Record, _ slot: Slot) -> ObjectIdentifier? {
        if case .ref(let node) = edge.peek(slot) { return ObjectIdentifier(node) }
        return nil
    }

    /// Edges in order with every node at most once; null edges are dropped.
    private static func merged(_ first: ContiguousArray<Record?>, _ second: ContiguousArray<Record?>, nodeSlot: Slot) -> ContiguousArray<Record?> {
        var result = ContiguousArray<Record?>()
        result.reserveCapacity(first.count + second.count)
        var seen = Set<ObjectIdentifier>()
        seen.reserveCapacity(first.count + second.count)
        for case let edge? in first {
            if let node = node(of: edge, nodeSlot), !seen.insert(node).inserted { continue }
            result.append(edge)
        }
        for case let edge? in second {
            if let node = node(of: edge, nodeSlot), !seen.insert(node).inserted { continue }
            result.append(edge)
        }
        return result
    }

    /// Merges a page into its connection record, as Relay's connection handler
    /// does: the connection's own fields follow the page; edges replace,
    /// append or prepend by the cursor the page was fetched with, deduplicated
    /// by node; the page info merges per direction. A page fetched after a
    /// cursor that is no longer the end is ignored.
    private func merge(_ connection: Record, page: Record, slots: ConnectionSlots, mode: ConnectionMode, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        page.forEachValue { slot, value in
            if slot.index == slots.edges.index || slot.index == slots.pageInfoLink.index { return }
            set(connection, Slot(type: slots.connection, index: slot.index), value, &transaction, &undo)
        }

        let pageInfo: Record
        if case .ref(let existing) = connection.peek(slots.pageInfoLink) {
            pageInfo = existing
        } else {
            pageInfo = record(key: connection.key + ":pageInfo", type: slots.pageInfo, entity: false)
            set(connection, slots.pageInfoLink, .ref(pageInfo), &transaction, &undo)
        }
        let existing = Store.edges(connection, slots.edges)
        let incoming = Store.edges(page, slots.edges)
        let merged: ContiguousArray<Record?>
        let copied: [Slot]
        switch mode {
        case .replace:
            merged = Store.merged(incoming, [], nodeSlot: slots.node)
            copied = [slots.hasNextPage, slots.hasPreviousPage, slots.startCursor, slots.endCursor]
        case .append(let after):
            if let after, !existing.isEmpty, case .string(let end) = pageInfo.peek(slots.endCursor), end != after { return }
            merged = Store.merged(existing, incoming, nodeSlot: slots.node)
            copied = [slots.hasNextPage, slots.endCursor]
        case .prepend(let before):
            if let before, !existing.isEmpty, case .string(let start) = pageInfo.peek(slots.startCursor), start != before { return }
            merged = Store.merged(incoming, existing, nodeSlot: slots.node)
            copied = [slots.hasPreviousPage, slots.startCursor]
        }
        set(connection, slots.edges, .refs(merged), &transaction, &undo)
        if case .ref(let serverPageInfo) = page.peek(slots.pageInfoLink) {
            for slot in copied {
                let value = serverPageInfo.peek(slot)
                if case .missing = value { continue }
                set(pageInfo, slot, value, &transaction, &undo)
            }
        }
    }

    /// The connection an edge directive names, with the slots the plans
    /// resolved for its type, so the edit looks no key up by name. A record
    /// of a type no connection field describes is not a connection, and the
    /// edit leaves it alone.
    private func editableConnection(_ key: String) -> (record: Record, slots: ConnectionSlots)? {
        guard let connection = editable(key), let slots = Registry.connectionSlots(of: connection.type) else { return nil }
        return (connection, slots)
    }

    /// Inserts a copy of a payload's edge into a connection named by id, unless
    /// an edge for the same node is already there. The copy is the
    /// connection's own record, as in Relay: the payload's edge record is
    /// keyed by its path, so the next mutation of the same kind would alias it.
    /// An edge of another type than the connection's, whose slots the
    /// connection's readers do not read, is not inserted.
    private func insert(edge: Record, into connectionKey: String, prepend: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard case let (connection, slots)? = editableConnection(connectionKey), edge.type == slots.edge else { return }
        if contains(connection, node: Store.node(of: edge, slots.node), slots) { return }
        let copy = ownEdge(of: connection, slots, &transaction, &undo)
        edge.forEachValue { slot, value in
            set(copy, Slot(type: slots.edge, index: slot.index), value, &transaction, &undo)
        }
        append(copy, to: connection, slots, prepend: prepend, &transaction, &undo)
    }

    /// Wraps a node in a new edge record of the connection and inserts it,
    /// when the edge type the directive names is the connection's.
    private func insert(node: Record, edgeType: TypeID, into connectionKey: String, prepend: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard case let (connection, slots)? = editableConnection(connectionKey), edgeType == slots.edge else { return }
        if contains(connection, node: ObjectIdentifier(node), slots) { return }
        let edge = ownEdge(of: connection, slots, &transaction, &undo)
        set(edge, slots.node, .ref(node), &transaction, &undo)
        set(edge, slots.cursor, .null, &transaction, &undo)
        append(edge, to: connection, slots, prepend: prepend, &transaction, &undo)
    }

    /// A new edge record owned by the connection, numbered by Relay's
    /// `__connection_next_edge_index` client field.
    private func ownEdge(of connection: Record, _ slots: ConnectionSlots, _ transaction: inout Transaction, _ undo: inout [Undo]) -> Record {
        let index: Int = if case .int(let index) = connection.peek(slots.nextEdgeIndex) { index } else { 0 }
        set(connection, slots.nextEdgeIndex, .int(index + 1), &transaction, &undo)
        return record(key: connection.key + ":edges:" + String(index), type: slots.edge, entity: false)
    }

    private func contains(_ connection: Record, node: ObjectIdentifier?, _ slots: ConnectionSlots) -> Bool {
        guard let node else { return false }
        for case let edge? in Store.edges(connection, slots.edges) where Store.node(of: edge, slots.node) == node {
            return true
        }
        return false
    }

    private func append(_ edge: Record, to connection: Record, _ slots: ConnectionSlots, prepend: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        var edges = Store.edges(connection, slots.edges)
        if prepend { edges.insert(edge, at: 0) } else { edges.append(edge) }
        set(connection, slots.edges, .refs(edges), &transaction, &undo)
    }

    /// Removes every edge whose node is an entity with this id, of whatever
    /// type, from a connection named by id.
    private func deleteEdges(of id: String, from connectionKey: String, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard case let (connection, slots)? = editableConnection(connectionKey) else { return }
        let edges = Store.edges(connection, slots.edges)
        let kept = edges.filter { edge in
            guard let edge, case .ref(let node) = edge.peek(slots.node) else { return true }
            return !node.hasID(id)
        }
        if kept.count == edges.count { return }
        set(connection, slots.edges, .refs(ContiguousArray(kept)), &transaction, &undo)
    }

    /// Deletes a record: its values are cleared through the batch, which
    /// tells the bodies that read them, and it is marked deleted, so links to
    /// it read as null and lists skip it; the batch's end tells the bodies
    /// that hold a link to it.
    private func delete(_ record: Record, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        record.forEachValue { slot, _ in
            set(record, slot, .missing, &transaction, &undo)
        }
        setDeleted(record, true, &transaction, &undo)
    }

    // MARK: Availability, marking, sweeping

    /// Whether every field of the selection is present, starting at `record`.
    /// A missing root link with a lookup is satisfied by the cached entity,
    /// and the link is written so later reads are direct.
    ///
    /// Memory answers first. When it cannot and the store has an image, the
    /// same walk runs again with the image at hand, and what it reads becomes
    /// part of the store: this is how a launch renders its first body from
    /// the last one's data.
    package func check(_ selection: ResolvedSelection, at record: Record? = nil) -> Answer {
        let record = record ?? root
        metHydrated = false
        if available(selection, at: record, from: nil) { return metHydrated ? .image : .memory }
        // A check an observer starts while the image is being read joins
        // the read that is open.
        if let reading { return available(selection, at: record, from: reading) ? .image : .miss }
        guard let persistence else { return .miss }
        let found = persistence.reading { disk in
            reading = disk
            defer { reading = nil }
            return available(selection, at: record, from: disk)
        }
        return found ? .image : .miss
    }

    /// Whether every deferred part of a selection the check found is whole,
    /// in memory or, through the check, in the image. The check passes over
    /// deferred fields, while a record read from the image holds every cell
    /// of its row, a deferred fragment's link among them, with nothing
    /// behind it: such a field is cleared, so its fragment reads absent
    /// rather than empty, unless the initial part reads the same field and
    /// its data is there. Either way the answer is false, so the operation
    /// fetches.
    func deferredPartsHold(_ selection: ResolvedSelection, at record: Record? = nil) -> Bool {
        var whole = true
        deferredParts(selection, at: record ?? root, &whole)
        return whole
    }

    private func deferredParts(_ selection: ResolvedSelection, at record: Record, _ whole: inout Bool) {
        let fields = selection.isAbstract ? selection.variant(for: record.type).fields : selection.fields
        for field in fields where !field.isTypename {
            let value = record.peek(field.slot)
            guard case .linked(let child, _, _, _) = field.kind else {
                if field.deferred != nil, case .missing = value { whole = false }
                continue
            }
            var targets: [Record] = []
            switch value {
            case .ref(let target) where !target.deleted: targets = [target]
            case .refs(let list): targets = list.compactMap { $0 }.filter { !$0.deleted }
            case .missing: if field.deferred != nil { whole = false }
            default: break
            }
            guard field.deferred != nil else {
                for target in targets { deferredParts(child, at: target, &whole) }
                continue
            }
            if targets.contains(where: { check(child, at: $0) == .miss }) {
                // A slot that a field outside the deferred part reads as
                // well keeps its value: it is that field's data.
                if !fields.contains(where: { $0.deferred == nil && $0.slot == field.slot }) {
                    record.write(field.slot, .missing)
                }
                whole = false
            }
        }
    }

    /// Where the availability check found the selection's data.
    package enum Answer: Sendable {
        /// In memory, every record of it put there by a response.
        case memory
        /// With the image's help: read from it now, or by an earlier check.
        case image
        /// Not all of it, in memory or in the image.
        case miss
    }

    /// The availability walk: whether every field of the selection is
    /// present at `record`. Without a disk it reads memory as it stands; with
    /// one, a record that lacks a field reads its row first, a link to a
    /// record the collector swept is pointed at the live record of that key,
    /// and a connection's client record is walked while it holds nothing.
    private func available(_ selection: ResolvedSelection, at record: Record, from disk: Disk?) -> Bool {
        selection.isAbstract ? available(selection.variant(for: record.type).fields, at: record, from: disk) : available(selection.fields, at: record, from: disk)
    }

    /// The walk over one record's fields. They are taken as a parameter and
    /// read in place, so neither the list nor a field is retained per record.
    private func available(_ fields: [ResolvedField], at record: Record, from disk: Disk?) -> Bool {
        if disk == nil {
            if record.hydrated {
                metHydrated = true
            } else if record === root, !hydratedRootSlots.isEmpty, readsHydratedRootSlot(fields) {
                metHydrated = true
            }
        }
        for index in fields.indices {
            if fields[index].isTypename || fields[index].deferred != nil { continue }
            let slot = fields[index].slot
            if let disk, case .missing = record.peek(slot) { hydrate(record, slot, from: disk) }
            switch fields[index].kind {
            case .scalar:
                if case .missing = record.peek(slot) { return false }
            case .linked(let child, let plural, let lookupKey, let connection):
                switch record.peek(slot) {
                case .missing:
                    guard !plural, let lookupKey, let target = resolve(lookupKey, disk) else { return false }
                    guard available(child, at: target, from: disk) else { return false }
                    record.write(slot, .ref(target))
                case .null:
                    break
                case .ref(let found):
                    var target = found
                    if let disk {
                        target = live(found, disk)
                        if target !== found { record.write(slot, .ref(target)) }
                    }
                    if !target.deleted, !available(child, at: target, from: disk) { return false }
                case .refs(var targets):
                    if let disk {
                        var moved = false
                        for position in targets.indices {
                            guard let found = targets[position] else { continue }
                            let target = live(found, disk)
                            if target !== found {
                                targets[position] = target
                                moved = true
                            }
                        }
                        if moved { record.write(slot, .refs(targets)) }
                    }
                    for case let target? in targets where !target.deleted && !available(child, at: target, from: disk) { return false }
                default:
                    return false
                }
                // Lenses read a connection through its client record, which
                // the walk above does not pass. A merge always fills it, so
                // one that holds nothing, swept or never filled, is not in
                // memory: the image may hold it, or have been told to forget
                // it. With the image at hand it is walked, so its merged
                // pages come back with it, and one the image has no row for
                // stays a miss.
                if let connection, case .ref(let found) = record.peek(connection.slot), found.swept || found.isEmpty {
                    guard let disk else { return false }
                    let merged = live(found, disk)
                    if merged !== found { record.write(connection.slot, .ref(merged)) }
                    if !merged.deleted, !available(child, at: merged, from: disk) { return false }
                }
            }
        }
        return true
    }

    /// Whether the walk reads one of the root's fields the image filled:
    /// taken once, before the walk, so the records below pay nothing for it.
    private func readsHydratedRootSlot(_ fields: [ResolvedField]) -> Bool {
        for index in fields.indices where !fields[index].isTypename && fields[index].deferred == nil {
            if hydratedRootSlots.contains(fields[index].slot.index) { return true }
        }
        return false
    }

    /// A link's target as the store and the image know it together: the live
    /// record of the key when the collector swept the one the link holds,
    /// and, for a record that holds nothing yet, its row, so that whether it
    /// was deleted is known before the walk decides to enter it.
    private func live(_ found: Record, _ disk: Disk) -> Record {
        let record = found.swept ? target(key: found.key, type: found.type, entity: found.isEntity) : found
        if !record.hydrated, record.isEmpty, record !== root, record !== mutationRoot, record !== subscriptionRoot {
            _ = hydrate(record, from: disk)
        }
        return record
    }

    /// Reads from the image what a record lacks: the root's field, or the
    /// record's row, once.
    private func hydrate(_ record: Record, _ slot: Slot, from disk: Disk) {
        if record === root {
            _ = hydrateRoot(slot, from: disk)
        } else if !record.hydrated, record !== mutationRoot, record !== subscriptionRoot {
            _ = hydrate(record, from: disk)
        }
    }

    /// Collects every record the selection reaches from the root, for
    /// collection. A connection is reached through its client slot as well as
    /// through the page the operation fetched, so merged pages live as long as
    /// any root reaches the connection.
    func mark(_ selection: ResolvedSelection, from record: Record? = nil, into reachable: inout Set<ObjectIdentifier>) {
        let record = record ?? root
        reachable.insert(ObjectIdentifier(record))
        if selection.isAbstract {
            mark(selection.variant(for: record.type).fields, from: record, into: &reachable)
        } else {
            mark(selection.fields, from: record, into: &reachable)
        }
    }

    private func mark(_ fields: [ResolvedField], from record: Record, into reachable: inout Set<ObjectIdentifier>) {
        for index in fields.indices {
            guard case .linked(let child, _, _, let connection) = fields[index].kind else { continue }
            mark(record.peek(fields[index].slot), child, into: &reachable)
            if let connection {
                mark(record.peek(connection.slot), child, into: &reachable)
            }
        }
    }

    private func mark(_ value: Value, _ child: ResolvedSelection, into reachable: inout Set<ObjectIdentifier>) {
        switch value {
        case .ref(let target):
            mark(child, from: target, into: &reachable)
        case .refs(let targets):
            for case let target? in targets {
                mark(child, from: target, into: &reachable)
            }
        default:
            return
        }
    }

    /// Removes every record not in `reachable` (the roots stay), clears their
    /// slots so cycles break, and drops the roots' links to them. Returns how
    /// many records were removed.
    @discardableResult
    func sweep(keeping reachable: Set<ObjectIdentifier>) -> Int {
        // The keys first, then the removals: removing from the dictionary
        // while iterating it copies the whole dictionary at the first one.
        var unreachable: [String] = []
        for (key, record) in records
        where key != Store.rootKey && key != Store.mutationRootKey && key != Store.subscriptionRootKey && !reachable.contains(ObjectIdentifier(record)) {
            unreachable.append(key)
        }
        var swept = Set<ObjectIdentifier>(minimumCapacity: unreachable.count)
        for key in unreachable {
            guard let record = records.removeValue(forKey: key) else { continue }
            swept.insert(ObjectIdentifier(record))
            record.clear()
        }
        if !swept.isEmpty {
            root.prune(swept)
            mutationRoot.prune(swept)
            subscriptionRoot.prune(swept)
        }
        return swept.count
    }

    /// The record and selection a response path names, from the root: for an
    /// incremental part's `path`. Nil when the path leads through data the
    /// store never received.
    func walk(_ path: [Ingest.PathSegment], _ selection: ResolvedSelection, from record: Record? = nil) -> (Record, ResolvedSelection)? {
        var record = record ?? root
        var selection = selection
        var segments = path[...]
        while let segment = segments.popFirst() {
            let variant = selection.variant(for: record.type)
            guard case .name(let name) = segment, let index = variant.field(named: name),
                  case .linked(let child, _, _, _) = variant.fields[index].kind
            else { return nil }
            switch record.peek(variant.fields[index].slot) {
            case .ref(let target):
                record = target
            case .refs(let targets):
                guard case .index(let offset)? = segments.popFirst(), targets.indices.contains(offset), let target = targets[offset] else { return nil }
                record = target
            default:
                return nil
            }
            selection = child
        }
        return (record, selection)
    }

    /// The live entities with this id among the named types.
    private func live(id: String, among typeNames: [String]) -> [Record] {
        var found: [Record] = []
        for name in typeNames {
            if let record = records[name + ":" + id], !record.deleted { found.append(record) }
        }
        return found
    }

    /// The entity a lookup names, if cached and not deleted. With the image
    /// at hand, an entity only the image holds counts when its type is known.
    func resolve(_ lookup: LookupKey, _ disk: Disk? = nil) -> Record? {
        if let type = lookup.type {
            return resolve(type, lookup.value, disk)
        }
        // Without a type, the field's possible types are probed; an id they
        // share among live records resolves to none of them.
        if let record = entity(id: lookup.value, among: lookup.possibleTypes.map(\.name)) { return record }
        guard let disk else { return nil }
        let found = lookup.possibleTypes.compactMap { resolve($0, lookup.value, disk) }
        guard found.count == 1 else {
            if found.count > 1 { reportAmbiguousIdentity?(lookup.value, found) }
            return nil
        }
        return found[0]
    }

    /// The entity `Type:id`: live in memory, or, with the image at hand, read
    /// from it. A record is registered only once the image had its row, so
    /// a miss leaves nothing behind.
    private func resolve(_ type: TypeID, _ id: String, _ disk: Disk?) -> Record? {
        let key = type.name + ":" + id
        if let record = records[key] { return record.deleted ? nil : record }
        guard let disk else { return nil }
        let candidate = Record(type: type, key: key, idOffset: Int32(type.name.utf8.count + 1))
        guard hydrate(candidate, from: disk) else { return nil }
        records[key] = candidate
        return candidate.deleted ? nil : candidate
    }

    /// The one live entity with this id among the named types. None, or an
    /// id more than one of them has, is no record; the second is reported.
    private func entity(id: String, among typeNames: [String]) -> Record? {
        let found = live(id: id, among: typeNames)
        guard found.count == 1 else {
            if found.count > 1 { reportAmbiguousIdentity?(id, found) }
            return nil
        }
        return found[0]
    }
}
