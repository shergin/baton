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
    /// Called once a batch that changed a null, an error or a link has
    /// notified, for the phases that read them; the environment sets it.
    var phasesNeedSettling: (() -> Void)?
    /// Whether the store's session has ended: it holds nothing, commits
    /// nothing more and reports nothing.
    package private(set) var ended = false

    /// The environment's log, called with each event of the store's and the
    /// image's work; the image's writer gets its own copy, since it runs off
    /// the main actor. Debug builds print the missing-data events until it
    /// is set.
    package var log: (@Sendable (LogEvent) -> Void)? {
        didSet { persistence?.setLog(log) }
    }

    /// The stand-in a non-null link without a record reads, one per type and
    /// never in `records`: its fields are all missing, and the anchor over it
    /// has no store, so a lens below reads zero values and reports nothing a
    /// second time.
    private var placeholders: [TypeID: Record] = [:]

    /// Bumped by `invalidate()`; handles fetched before it are stale.
    package private(set) var invalidationEpoch = 0

    /// Optimistic responses currently applied, oldest first.
    package private(set) var optimisticLayers: [OptimisticLayer] = []

    /// The store's image on disk, when it has one: every commit is written
    /// behind, and the availability check reads from it what memory lacks.
    public let persistence: Persistence?
    /// The keys the store's session renders from variables, numbered by the
    /// store and forgotten at its end.
    package nonisolated let keys = Keys()
    /// Slots that hold one key, each the other's twin: the store's number
    /// for a text and the constant the build named for it afterwards. A
    /// write to either lands in both. Bounded by the build's constants.
    var twins: [Slot: Slot] = [:]
    /// How old an operation's data may be before it reads as stale, for an
    /// operation whose document states no `@cacheExpiration` of its own;
    /// `nil` is forever. Given when the store is made, where Relay gives it.
    public let cacheExpiration: Duration?
    /// How far ahead of the continuous clock the store reads; for the tests
    /// and the fixtures' scripts, which advance time rather than wait for it.
    package var clockOffset: Duration = .zero
    /// The store's clock, read for every stamp and every staleness: the
    /// continuous clock, run ahead by `clockOffset`.
    var now: ContinuousClock.Instant { .now + clockOffset }
    /// The wall clock the image keeps ages by, run ahead the same way.
    var wallNow: Double {
        let (seconds, attoseconds) = clockOffset.components
        return Date().timeIntervalSince1970 + Double(seconds) + Double(attoseconds) / 1e18
    }
    /// How many released roots keep their records alive, oldest out first,
    /// and how many completed mutations keep their payloads, apart from them.
    public let releaseBufferSize: Int
    /// The roots, by the operation's key: retained, waiting in the release
    /// buffer, or a completed mutation's.
    var roots: [String: Root] = [:]
    /// Released roots, oldest first.
    var releaseBuffer: [String] = []
    /// Completed mutations' roots, oldest first, apart from the buffer.
    var completedMutations: [String] = []
    var collectionScheduled = false
    /// How many collections have run; for tests and benchmarks.
    package internal(set) var collections = 0
    /// Whether the batch in progress moved or dropped a link, which may have
    /// orphaned what the link reached: a pass follows the batch.
    private var linkDropped = false
    /// How many records have been filled from the image; for tests and
    /// benchmarks.
    package internal(set) var hydratedRecords = 0
    /// The root's fields the image filled, by slot index. The image stores
    /// the root a row per field and the root is never marked hydrated, so
    /// these tell the walk in memory which of its fields came from there.
    var hydratedRootSlots: Set<Int32> = []
    /// Whether the batch in progress changed a field error, a null, a link,
    /// or whether a record is deleted: what `@throwOnFieldError` and
    /// bubbling `@required` read.
    private var nullsOrErrorsChanged = false

    public init(persistence: Persistence? = nil, cacheExpiration: Duration? = nil, releaseBufferSize: Int = 10) {
        self.persistence = persistence
        self.cacheExpiration = cacheExpiration
        self.releaseBufferSize = releaseBufferSize
        root = Record(type: Registry.type("Query"), key: Store.rootKey)
        mutationRoot = Record(type: Registry.type("Mutation"), key: Store.mutationRootKey)
        subscriptionRoot = Record(type: Registry.type("Subscription"), key: Store.subscriptionRootKey)
        records[Store.rootKey] = root
        records[Store.mutationRootKey] = mutationRoot
        records[Store.subscriptionRootKey] = subscriptionRoot
        #if DEBUG
        log = { event in
            if let line = event.debugDescription { print(line) }
        }
        persistence?.setLog(log)
        #endif
    }

    /// Ends the store, once and for good: the roots go, every record is
    /// cleared, and nothing is committed or reported after. The image is the
    /// environment's to close, since closing waits for the writer.
    func end() {
        guard !ended else { return }
        ended = true
        roots.removeAll()
        releaseBuffer.removeAll()
        completedMutations.removeAll()
        optimisticLayers.removeAll()
        for record in records.values { record.clear() }
        records = [Store.rootKey: root, Store.mutationRootKey: mutationRoot, Store.subscriptionRootKey: subscriptionRoot]
        placeholders.removeAll()
        log = nil
        phasesNeedSettling = nil
    }

    /// A store dropped without an end clears its records, so that records
    /// which link to each other are freed with it: the net, not the end.
    isolated deinit {
        for record in records.values { record.clear() }
    }

    /// Marks everything fetched so far as stale, in memory and in the image;
    /// `Environment.invalidate()` is the public way, which also refetches.
    func invalidate() {
        guard !ended else { return }
        invalidationEpoch += 1
        persistence?.invalidate()
    }

    /// The storage key a slot stands for: the field's name with its
    /// arguments rendered, as a report names it.
    @_spi(Generated) public func storageKey(of slot: Slot) -> String {
        keys.text(of: slot)
    }

    /// Adopts the constants the build named after the store rendered their
    /// texts: the store's number and the constant's slot become twins, the
    /// records' values under the one are copied under the other, and every
    /// later write to either lands in both, so a text keeps one slot
    /// whichever way it was met first. Free when nothing waits.
    func adoptConstants() {
        guard keys.hasAdoptions.load(ordering: .relaxed) else { return }
        for (rendered, dense) in keys.takeAdoptions() {
            twins[rendered] = dense
            twins[dense] = rendered
            for record in records.values where record.type == rendered.type && record.twin(rendered, dense) {
                record.notify(dense)
            }
        }
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
    /// Every field a record holds, by storage key, with its error; a key the
    /// store holds at two slots, a rendering and the constant adopted for
    /// it, is one field. For the store dumps under `spec/` and the
    /// inspector.
    package func storedFields(of record: Record) -> [(key: String, value: Value, error: FieldError?)] {
        record.storedSlots.compactMap { slot, value, error in
            // The rendered half of a twin pair yields to the constant's.
            if slot.index < 0, !twins.isEmpty, twins[slot] != nil { return nil }
            return (keys.text(of: slot), value, error)
        }
    }


    /// Every record the store holds, by key; for the store dumps under `spec/`.
    package var recordsByKey: [String: Record] { records }

    /// The record for a key, created on first sight.
    func record(key: String, type: TypeID, idOffset: Int32) -> Record {
        record(key: key, type: type, idOffset: idOffset).record
    }

    /// The record for a key, and whether this call created it.
    private func record(key: String, type: TypeID, idOffset: Int32) -> (record: Record, created: Bool) {
        if let record = records[key] {
            // A key names one type: an entity's starts with it, and a path
            // key under an interface or union ends with it.
            assert(record.type == type, "\(key) is a \(record.type.name), not a \(type.name)")
            return (record, false)
        }
        let record = Record(type: type, key: key, idOffset: idOffset)
        records[key] = record
        return (record, true)
    }

    /// The record a stored link names: the one the store holds, deleted or
    /// not, or a new empty one for the image to fill.
    func target(key: String, type: TypeID, entity: Bool) -> Record {
        if let record = records[key] { return record }
        // A row says of a link's target that it is an entity, not where its
        // id starts: the type's name gives that, once per target the image
        // names that memory lacks.
        return record(key: key, type: type, idOffset: entity ? Record.idOffset(ofType: type.name) : -1)
    }

    // MARK: Commits and optimistic layers

    /// A pending optimistic response: its change set, and what it overwrote.
    package struct OptimisticLayer: Identifiable, Sendable {
        package let id: UUID
        package let changes: ChangeSet
        var undo: [Undo] = []

        /// The rendered keys the layer writes and its undo restores: kept
        /// while the layer is applied.
        func slots(into slots: inout Set<Slot>) {
            for entry in changes.entries where entry.slot.index < 0 { slots.insert(entry.slot) }
            for entry in changes.fieldErrors where entry.slot.index < 0 { slots.insert(entry.slot) }
            for step in undo {
                switch step {
                case .slot(_, let slot, _) where slot.index < 0: slots.insert(slot)
                case .error(_, let slot, _) where slot.index < 0: slots.insert(slot)
                default: continue
                }
            }
        }
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
            /// Whether the slot counts among the changed: a twin's write is
            /// the same key written again, notified on its own channel and
            /// counted with its twin.
            let counted: Bool
            let record: Record
            let slot: Slot
            let value: Value
            let error: FieldError?
        }

        init(direct: Bool = false) {
            self.direct = direct
        }

        /// Notes a slot about to change, with what it held before. A twin's
        /// write is notified, so the readers through the other slot hear of
        /// it, and not counted, since it is one key.
        mutating func touched(_ record: Record, _ slot: Slot, value: Value, error: FieldError?, twin: Bool = false) {
            if direct {
                record.notify(slot)
                if !twin { directCount += 1 }
                return
            }
            let key = SlotKey(record: ObjectIdentifier(record), slot: slot)
            if originals[key] == nil { originals[key] = Original(record: record, slot: slot, value: value, error: error, counted: !twin) }
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
                if original.counted { changed += 1 }
            }
            return changed
        }
    }

    /// One batch of writes to records: the transaction that nets its
    /// notifications, the undo log of what it changed, and its kind. A
    /// server batch is written to the image; an optimistic one keeps its undo
    /// with its layer, and the image is not told; a local one, the runtime's
    /// own writes, neither. Nothing outside a batch writes a record, and
    /// notifications fire when the batch ends.
    @MainActor
    struct Batch {
        enum Kind {
            case server
            case optimistic
            case local
        }

        let kind: Kind
        private var transaction: Transaction
        /// The steps taken, each as it was before: for undoing a layer, and
        /// for what the image is told.
        private(set) var undo: [Undo] = []
        /// Whether steps are kept: not while a layer is lifted, whose steps
        /// undo an earlier log.
        var keepsUndo = true

        init(_ kind: Kind, direct: Bool = false) {
            self.kind = kind
            transaction = Transaction(direct: direct)
            keepsUndo = kind != .local
        }

        mutating func touched(_ record: Record, _ slot: Slot, value: Value, error: FieldError?, twin: Bool = false) {
            transaction.touched(record, slot, value: value, error: error, twin: twin)
        }

        mutating func flagged(_ record: Record, was: Bool) {
            transaction.flagged(record, was: was)
        }

        mutating func record(_ step: Undo) {
            if keepsUndo { undo.append(step) }
        }

        /// The steps taken since `start`, for a layer's own log.
        func steps(since start: Int) -> [Undo] {
            Array(undo[start...])
        }

        /// Notifies the slots that changed; how many did.
        func finish() -> Int { transaction.finish() }

        /// The records whose deleted flag differs at the end.
        var flipped: [Record] { transaction.flipped }
    }

    /// Ends a batch: notifies the slots that changed, and when the batch
    /// changed whether records are deleted, every slot that links to one of
    /// them, since a link to a deleted record reads as null and a list skips
    /// it. Returns how many slots changed.
    private func finish(_ batch: Batch) -> Int {
        if linkDropped {
            linkDropped = false
            scheduleCollection()
        }
        let changed = batch.finish()
        // A local batch is the runtime's own writing, as frequent as a read
        // walk; the log hears of what the server and the app wrote.
        switch batch.kind {
        case .server: log?(.committed(kind: .server, changed: changed))
        case .optimistic: log?(.committed(kind: .optimistic, changed: changed))
        case .local: break
        }
        let flipped = batch.flipped
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
        commit(changes, replacingOptimistic: nil)
    }

    /// The server's commit: the one server batch. With `id`, the server's
    /// answer to an optimistic mutation replaces the layer in the same
    /// batch.
    @discardableResult
    package func commit(_ changes: ChangeSet, replacingOptimistic id: UUID?) -> Int {
        adoptConstants()
        defer { reevaluateIfNeeded() }
        if id == nil, optimisticLayers.isEmpty {
            var batch = Batch(.server, direct: true)
            applyServer(changes, into: &batch)
            return finish(batch)
        }
        var batch = Batch(.server)
        revertLayers(from: 0, into: &batch)
        if let id { optimisticLayers.removeAll { $0.id == id } }
        applyServer(changes, into: &batch)
        reapplyLayers(from: 0, into: &batch)
        return finish(batch)
    }

    /// Lets the environment settle the phases that read errors and nulls,
    /// once the batch that changed one has notified.
    private func reevaluateIfNeeded() {
        guard nullsOrErrorsChanged else { return }
        nullsOrErrorsChanged = false
        phasesNeedSettling?()
    }

    /// Applies a server's payload and hands the image what it changed, and
    /// what it could not change in memory, for the image to forget.
    private func applyServer(_ changes: ChangeSet, into batch: inout Batch) {
        // Without an image an edit memory cannot make is simply not made.
        forgets = persistence == nil ? nil : Forgets()
        let start = batch.undo.count
        apply(changes, into: &batch)
        if let forgets, !forgets.keys.isEmpty || !forgets.ids.isEmpty {
            persistence?.forget(keys: forgets.keys, ids: forgets.ids)
            forgotten.note(keys: forgets.keys, ids: forgets.ids)
        }
        forgets = nil
        // The records the payload wrote are the store's again, by their exact
        // keys; the others with a forgotten id stay unread until the writer
        // has dropped them.
        if !forgotten.isEmpty {
            for index in changes.recordKeys.indices {
                forgotten.wrote(changes.recordKeys[index], isEntity: changes.recordIsEntity[index])
            }
        }
        persist(batch.steps(since: start))
    }

    /// What a server batch could not edit in memory: connection keys, and
    /// the bare ids of records `@deleteRecord` named that memory does not
    /// hold. Recorded only while a server's payload applies.
    struct Forgets {
        var keys: [String] = []
        var ids: [String] = []
    }

    var forgets: Forgets?

    /// What the image was told to forget and has not yet.
    private var forgotten = Persistence.Forgotten()

    /// Whether the image's row of a record is not to be read. Once no forget
    /// waits for the writer, the rows are gone and nothing is forgotten.
    func forgotten(_ record: Record) -> Bool {
        if forgotten.isEmpty { return false }
        guard persistence?.forgetting == true else {
            forgotten.clear()
            return false
        }
        return forgotten.contains(record)
    }

    /// A changed field of the query root, which the image stores a row per
    /// field.
    struct RootField: Sendable {
        let slot: Slot
        let value: Value
        let error: FieldError?
    }

    /// Hands the image what a server's payload changed: a snapshot of every
    /// changed record, and the changed fields of the root one by one. Called
    /// while the optimistic layers are lifted, so the values are the server's.
    private func persist(_ undo: [Undo]) {
        guard let persistence, !undo.isEmpty else { return }
        var records: [Record.Snapshot] = []
        var fields: [RootField] = []
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
                    fields.append(RootField(slot: slot, value: root.peek(slot), error: root.peekError(slot)))
                } else {
                    add(record)
                }
            case .deletion(let record, _):
                add(record)
            }
        }
        if records.isEmpty, fields.isEmpty { return }
        persistence.committed(records, root: fields, keys: keys)
    }

    /// Applies an optimistic response on top of everything else.
    package func applyOptimistic(_ changes: ChangeSet) -> UUID {
        defer { reevaluateIfNeeded() }
        var batch = Batch(.optimistic)
        var layer = OptimisticLayer(id: UUID(), changes: changes)
        apply(changes, into: &batch)
        layer.undo = batch.undo
        optimisticLayers.append(layer)
        _ = finish(batch)
        return layer.id
    }

    /// Removes an optimistic layer; later layers are re-applied over the gap.
    package func revertOptimistic(_ id: UUID) {
        guard let index = optimisticLayers.firstIndex(where: { $0.id == id }) else { return }
        defer { reevaluateIfNeeded() }
        var batch = Batch(.optimistic)
        revertLayers(from: index, into: &batch)
        optimisticLayers.remove(at: index)
        reapplyLayers(from: index, into: &batch)
        _ = finish(batch)
    }

    private func revertLayers(from index: Int, into batch: inout Batch) {
        batch.keepsUndo = false
        defer { batch.keepsUndo = true }
        for layer in optimisticLayers[index...].reversed() {
            for undo in layer.undo.reversed() {
                switch undo {
                case .slot(let record, let slot, let value):
                    let error = record.peekError(slot)
                    if let previous = record.writeSilently(slot, value) {
                        batch.touched(record, slot, value: previous, error: error)
                        noteNulls(previous, value)
                    }
                case .error(let record, let slot, let error):
                    setError(record, slot, error, &batch)
                case .deletion(let record, let was):
                    setDeleted(record, was, &batch)
                }
            }
        }
        for position in index..<optimisticLayers.count {
            optimisticLayers[position].undo.removeAll()
        }
    }

    private func reapplyLayers(from index: Int, into batch: inout Batch) {
        // An optimistic response is never written to the image: its undo
        // log stays with the layer.
        for position in index..<optimisticLayers.count {
            let start = batch.undo.count
            apply(optimisticLayers[position].changes, into: &batch)
            optimisticLayers[position].undo = batch.steps(since: start)
        }
    }

    /// Writes one slot inside a batch, and its twin when it has one:
    /// silently, recorded for the net notification and for the undo log.
    func set(_ record: Record, _ slot: Slot, _ value: Value, _ batch: inout Batch) {
        write(record, slot, value, &batch)
        if !twins.isEmpty, let twin = twins[slot] { write(record, twin, value, &batch, twin: true) }
    }

    private func write(_ record: Record, _ slot: Slot, _ value: Value, _ batch: inout Batch, twin: Bool = false) {
        let error = record.peekError(slot)
        if let previous = record.writeSilently(slot, value) {
            batch.touched(record, slot, value: previous, error: error, twin: twin)
            batch.record(.slot(record, slot, previous))
            // A local write binds or repairs a link; it brings no new null
            // or error into a selection.
            if batch.kind != .local { noteNulls(previous, value) }
        }
    }

    /// Runs the runtime's own writes as one local batch, notified at its end:
    /// a loading flag, a link bound or repaired, a cell filled from the image.
    func local(_ writes: (inout Batch) -> Void) {
        var batch = Batch(.local)
        writes(&batch)
        _ = finish(batch)
    }

    /// Sets or clears a slot's field error inside a batch, and its twin's
    /// when it has one, recorded for the net notification and for the undo
    /// log.
    private func setError(_ record: Record, _ slot: Slot, _ error: FieldError?, _ batch: inout Batch) {
        setOwnError(record, slot, error, &batch)
        if !twins.isEmpty, let twin = twins[slot] { setOwnError(record, twin, error, &batch, twin: true) }
    }

    private func setOwnError(_ record: Record, _ slot: Slot, _ error: FieldError?, _ batch: inout Batch, twin: Bool = false) {
        let previous = record.peekError(slot)
        guard record.setError(slot, error) else { return }
        batch.touched(record, slot, value: record.peek(slot), error: previous, twin: twin)
        batch.record(.error(record, slot, previous))
        nullsOrErrorsChanged = true
    }

    /// Marks a record deleted or revives it inside a batch, recorded for the
    /// holders' notification and for the undo log.
    private func setDeleted(_ record: Record, _ deleted: Bool, _ batch: inout Batch) {
        guard record.deleted != deleted else { return }
        batch.flagged(record, was: record.deleted)
        batch.record(.deletion(record, was: record.deleted))
        record.setDeleted(deleted)
        nullsOrErrorsChanged = true
    }

    /// Notes for the batch a write to or from null, or a link that moved.
    @inline(__always)
    private func noteNulls(_ previous: Value, _ value: Value) {
        switch (previous, value) {
        case (.refs(let old), .refs(let new)):
            // A list that only grew, a page appended or prepended to a
            // connection, left what it reached reachable; one that changed
            // otherwise may not have.
            if !Store.keeps(old, in: new) { linkDropped = true }
            nullsOrErrorsChanged = true
        case (.ref, _), (.refs, _):
            // A link that moved, was nulled or was cleared may have left what
            // it reached unreachable.
            linkDropped = true
            nullsOrErrorsChanged = true
        case (.null, _), (_, .null):
            nullsOrErrorsChanged = true
        default:
            return
        }
    }

    /// Whether every link of `old` is still in `new`, which a page appended
    /// or prepended leaves true: `old` is a prefix or a suffix of `new`, by
    /// identity, with no set built.
    private static func keeps(_ old: ContiguousArray<Record?>, in new: ContiguousArray<Record?>) -> Bool {
        guard old.count <= new.count else { return false }
        if old.isEmpty { return true }
        var prefix = true
        var suffix = true
        let offset = new.count - old.count
        for index in old.indices {
            if prefix, old[index] !== new[index] { prefix = false }
            if suffix, old[index] !== new[offset + index] { suffix = false }
            if !prefix, !suffix { return false }
        }
        return true
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
    /// records delete. The batch keeps the undo log of what changed.
    private func apply(_ changes: ChangeSet, into batch: inout Batch) {
        // What the response said of types the build did not list, before any
        // body tests a record of them against a condition; the image keeps
        // it for the next launch.
        if !changes.memberships.isEmpty {
            for (type, condition) in changes.memberships { Membership.learn(type, of: condition) }
            persistence?.learned(changes.memberships.map { ($0.type.name, $0.condition.name) })
        }
        var objects = ContiguousArray<Record>()
        objects.reserveCapacity(changes.recordKeys.count)
        var created = [Bool](repeating: false, count: changes.recordKeys.count)
        for index in 0..<changes.recordKeys.count {
            let found = record(key: changes.recordKeys[index], type: changes.recordTypes[index], idOffset: changes.recordIDOffsets[index]) as (record: Record, created: Bool)
            objects.append(found.record)
            created[index] = found.created
        }

        // Slots this change set carries an error for keep it below rather
        // than clearing it here and setting it again.
        var erroring = Set<SlotKey>()
        for entry in changes.fieldErrors {
            erroring.insert(SlotKey(record: ObjectIdentifier(objects[Int(entry.record)]), slot: entry.slot))
        }

        for index in 0..<objects.count {
            let record = objects[index]
            // A deleted record a payload names again comes back.
            if record.deleted { setDeleted(record, false, &batch) }
            let range = Int(changes.starts[index])..<Int(changes.starts[index + 1])
            if created[index], !range.isEmpty {
                // A new record makes room once: for the highest dense slot it
                // receives, and for each key numbered apart. The change set
                // holds each slot of a record once.
                var highest: Int32 = -1
                var rendered = 0
                for position in range {
                    let slot = changes.entries[position].slot.index
                    if slot > highest {
                        highest = slot
                    } else if slot < 0 {
                        rendered &+= 1
                    }
                }
                record.reserve(dense: Int(highest) + 1, rendered: rendered)
            }
            for position in range {
                let entry = changes.entries[position]
                // A field the payload answers without an error has none, whether
                // or not its value changed.
                if record.hasErrors, record.peekError(entry.slot) != nil,
                   erroring.isEmpty || !erroring.contains(SlotKey(record: ObjectIdentifier(record), slot: entry.slot)) {
                    setError(record, entry.slot, nil, &batch)
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
                    // Nobody can have read a record this batch created: its
                    // slots, and their twins, are written without a
                    // notification and count among nothing changed.
                    if !twins.isEmpty, let twin = twins[entry.slot], let previous = record.writeSilently(twin, value) {
                        batch.record(.slot(record, twin, previous))
                    }
                    if let previous = record.writeSilently(entry.slot, value) {
                        batch.record(.slot(record, entry.slot, previous))
                        noteNulls(previous, value)
                    }
                } else {
                    set(record, entry.slot, value, &batch)
                }
            }
        }

        for edit in changes.edits {
            switch edit {
            case .merge(let connection, let page, let slots, let mode):
                merge(objects[Int(connection)], page: objects[Int(page)], slots: slots, mode: mode, &batch)
            case .insertEdge(let edge, let connections, let prepend):
                for key in connections {
                    insert(edge: objects[Int(edge)], into: key, prepend: prepend, &batch)
                }
            case .insertNode(let node, let edgeType, let connections, let prepend):
                for key in connections {
                    insert(node: objects[Int(node)], edgeType: edgeType, into: key, prepend: prepend, &batch)
                }
            case .deleteEdge(let id, let connections):
                for key in connections {
                    deleteEdges(of: id, from: key, &batch)
                }
            case .deleteRecord(let id):
                // The directive names a bare id; the record is the one live
                // entity of any type with it. One memory does not hold may
                // be in the image, which forgets every record with the id.
                let found = live(id: id, among: Registry.typeNames())
                switch found.count {
                case 0: forgets?.ids.append(id)
                case 1: delete(found[0], &batch)
                default: log?(.ambiguousIdentity(id: id, types: found.map(\.type.name)))
                }
            }
        }

        // Field errors land beside the field; an error arriving counts as a
        // change of the slot.
        for entry in changes.fieldErrors {
            setError(objects[Int(entry.record)], entry.slot, entry.error, &batch)
        }
    }

    // MARK: Deletion

    /// Deletes a record: its values are cleared through the batch, which
    /// tells the bodies that read them, and it is marked deleted, so links to
    /// it read as null and lists skip it; the batch's end tells the bodies
    /// that hold a link to it.
    private func delete(_ record: Record, _ batch: inout Batch) {
        record.forEachValue { slot, _ in
            set(record, slot, .missing, &batch)
        }
        setDeleted(record, true, &batch)
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
        adoptConstants()
        // What the image's responses taught in earlier launches, before the
        // walk resolves a variant for a type the plan did not list.
        if let persistence {
            for (type, condition) in persistence.takeMemberships() { Membership.learn(Registry.type(type), of: Registry.type(condition)) }
        }
        let record = record ?? root
        // What the walk writes, a lookup's link bound, a link repaired, a
        // cell filled from the image, is one local batch, notified once the
        // walk is over: nothing observes a walk in progress. The walk's state
        // is passed, never captured: a variable a closure captures is boxed,
        // and every `inout` pass of it then pays a dynamic exclusivity check.
        var walk = Walk(batch: Batch(.local))
        defer { _ = finish(walk.batch) }
        if available(selection, at: record, from: nil, &walk) { return walk.met ? .image : .memory }
        guard let persistence else { return .miss }
        let found = persistence.reading(&walk) { disk, walk in
            available(selection, at: record, from: disk, &walk)
        }
        return found ? .image : .miss
    }

    /// The state of one availability walk: the local batch of what it
    /// writes, and whether the walk in memory met a record or a root field
    /// the image filled.
    struct Walk {
        var batch: Batch
        var met = false
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
        var batch = Batch(.local)
        deferredParts(selection, at: record ?? root, &whole, &batch)
        _ = finish(batch)
        return whole
    }

    private func deferredParts(_ selection: ResolvedSelection, at record: Record, _ whole: inout Bool, _ batch: inout Batch) {
        let fields = selection.variant(for: record.type).read
        for field in fields {
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
                for target in targets { deferredParts(child, at: target, &whole, &batch) }
                continue
            }
            if targets.contains(where: { check(child, at: $0) == .miss }) {
                // A slot that a field outside the deferred part reads as
                // well keeps its value: it is that field's data.
                if !fields.contains(where: { $0.deferred == nil && $0.slot == field.slot }) {
                    set(record, field.slot, .missing, &batch)
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
    private func available(_ selection: ResolvedSelection, at record: Record, from disk: Disk?, _ walk: inout Walk) -> Bool {
        available(selection.variant(for: record.type), at: record, from: disk, &walk)
    }

    /// The walk over one record's fields the check waits for, then the
    /// connections' client links. The lists are the variant's, read in
    /// place, so neither a list nor a field is retained per record.
    private func available(_ variant: ResolvedVariant, at record: Record, from disk: Disk?, _ walk: inout Walk) -> Bool {
        let fields = variant.waits
        if disk == nil {
            if record.hydrated {
                walk.met = true
            } else if record === root, !hydratedRootSlots.isEmpty, readsHydratedRootSlot(fields) {
                walk.met = true
            }
        }
        for index in fields.indices {
            let slot = fields[index].slot
            if let disk, case .missing = record.peek(slot) { hydrate(record, slot, from: disk, &walk.batch) }
            switch fields[index].kind {
            case .scalar:
                if case .missing = record.peek(slot) { return false }
            case .linked(let child, let plural, let lookupKey, _):
                switch record.peek(slot) {
                case .missing:
                    guard !plural, let lookupKey, let target = resolve(lookupKey, disk, &walk.batch) else { return false }
                    guard available(child, at: target, from: disk, &walk) else { return false }
                    set(record, slot, .ref(target), &walk.batch)
                case .null:
                    break
                case .ref(let found):
                    var target = found
                    if let disk {
                        target = live(found, disk, &walk.batch)
                        if target !== found { set(record, slot, .ref(target), &walk.batch) }
                    }
                    if !target.deleted, !available(child, at: target, from: disk, &walk) { return false }
                case .refs(var targets):
                    if let disk {
                        var moved = false
                        for position in targets.indices {
                            guard let found = targets[position] else { continue }
                            let target = live(found, disk, &walk.batch)
                            if target !== found {
                                targets[position] = target
                                moved = true
                            }
                        }
                        if moved { set(record, slot, .refs(targets), &walk.batch) }
                    }
                    for case let target? in targets where !target.deleted && !available(child, at: target, from: disk, &walk) { return false }
                default:
                    return false
                }
            }
        }
        // A client field is never waited for, but the image holds what a
        // payload wrote: it is hydrated here, and the records behind a client
        // link brought back, without a miss for what no server sends.
        if let disk {
            for field in variant.payloadFields {
                let slot = field.slot
                if case .missing = record.peek(slot) { hydrate(record, slot, from: disk, &walk.batch) }
                guard case .linked(let child, _, _, _) = field.kind else { continue }
                switch record.peek(slot) {
                case .ref(let found):
                    let target = live(found, disk, &walk.batch)
                    if target !== found { set(record, slot, .ref(target), &walk.batch) }
                    if !target.deleted { _ = available(child, at: target, from: disk, &walk) }
                case .refs(var targets):
                    var moved = false
                    for position in targets.indices {
                        guard let found = targets[position] else { continue }
                        let target = live(found, disk, &walk.batch)
                        if target !== found {
                            targets[position] = target
                            moved = true
                        }
                    }
                    if moved { set(record, slot, .refs(targets), &walk.batch) }
                    for case let target? in targets where !target.deleted { _ = available(child, at: target, from: disk, &walk) }
                default:
                    break
                }
            }
        }
        // Lenses read a connection through its client record, which the walk
        // above does not pass. A merge always fills it, so one that holds
        // nothing, swept or never filled, is not in memory: the image may
        // hold it, or have been told to forget it. With the image at hand it
        // is walked, so its merged pages come back with it, and one the
        // image has no row for stays a miss. The root's link is a cell of
        // its own in the image, read here, since the walk above hydrates the
        // root a waited field at a time and waits for no client link.
        for link in variant.clientLinks {
            if let disk, case .missing = record.peek(link.slot) { hydrate(record, link.slot, from: disk, &walk.batch) }
            guard case .linked(let child, _, _, _) = link.kind, case .ref(let found) = record.peek(link.slot), found.swept || found.isEmpty else { continue }
            guard let disk else { return false }
            let merged = live(found, disk, &walk.batch)
            if merged !== found { set(record, link.slot, .ref(merged), &walk.batch) }
            if !merged.deleted, !available(child, at: merged, from: disk, &walk) { return false }
        }
        return true
    }

    /// Whether the walk reads one of the root's fields the image filled:
    /// taken once, before the walk, so the records below pay nothing for it.
    private func readsHydratedRootSlot(_ waits: [ResolvedField]) -> Bool {
        for index in waits.indices where hydratedRootSlots.contains(waits[index].slot.index) { return true }
        return false
    }

    /// A link's target as the store and the image know it together: the live
    /// record of the key when the collector swept the one the link holds,
    /// and, for a record that holds nothing yet, its row, so that whether it
    /// was deleted is known before the walk decides to enter it.
    private func live(_ found: Record, _ disk: Disk, _ batch: inout Batch) -> Record {
        let record = found.swept ? target(key: found.key, type: found.type, entity: found.isEntity) : found
        if !record.hydrated, record.isEmpty, record !== root, record !== mutationRoot, record !== subscriptionRoot {
            _ = hydrate(record, from: disk, &batch)
        }
        return record
    }

    /// Reads from the image what a record lacks: the root's field, or the
    /// record's row, once.
    private func hydrate(_ record: Record, _ slot: Slot, from disk: Disk, _ batch: inout Batch) {
        if record === root {
            _ = hydrateRoot(slot, from: disk, &batch)
        } else if !record.hydrated, record !== mutationRoot, record !== subscriptionRoot {
            _ = hydrate(record, from: disk, &batch)
        }
    }

    /// Collects every record the selection reaches from the root, for
    /// collection. A connection is reached through its client slot as well as
    /// through the page the operation fetched, so merged pages live as long as
    /// any root reaches the connection.
    func mark(_ selection: ResolvedSelection, from record: Record? = nil, into reachable: inout Set<ObjectIdentifier>) {
        let record = record ?? root
        reachable.insert(ObjectIdentifier(record))
        mark(selection.variant(for: record.type).follows, from: record, into: &reachable)
    }

    /// Follows the variant's links, the connections' client links among
    /// them.
    private func mark(_ follows: [ResolvedField], from record: Record, into reachable: inout Set<ObjectIdentifier>) {
        for index in follows.indices {
            guard case .linked(let child, _, _, _) = follows[index].kind else { continue }
            mark(record.peek(follows[index].slot), child, into: &reachable)
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

    /// Frees the numbers of rendered keys nothing can name any more: no live
    /// resolution or scope took them, no optimistic layer carries them, no
    /// row waiting for the image is written under them. The entries records
    /// keep under them go with them, and the image forgets their names.
    func freeKeys() {
        var kept = Set<Slot>()
        for layer in optimisticLayers { layer.slots(into: &kept) }
        persistence?.unwrittenSlots(into: &kept)
        let freed = keys.free(butKeeping: kept)
        guard !freed.isEmpty else { return }
        let set = Set(freed)
        for record in records.values { record.drop(set) }
        for slot in freed where slot.type == root.type { hydratedRootSlots.remove(slot.index) }
        persistence?.freed(freed)
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
    func resolve(_ lookup: LookupKey, _ disk: Disk?, _ batch: inout Batch) -> Record? {
        if let type = lookup.type {
            return resolve(type, lookup.value, disk, &batch)
        }
        // Without a type, the field's possible types are probed; an id they
        // share among live records resolves to none of them.
        let possibleTypes = lookup.possibleTypes?.types ?? []
        if let record = entity(id: lookup.value, among: possibleTypes.map(\.name)) { return record }
        guard let disk else { return nil }
        var found: [Record] = []
        for type in possibleTypes {
            if let record = resolve(type, lookup.value, disk, &batch) { found.append(record) }
        }
        guard found.count == 1 else {
            if found.count > 1 { log?(.ambiguousIdentity(id: lookup.value, types: found.map(\.type.name))) }
            return nil
        }
        return found[0]
    }

    /// The entity `Type:id`: live in memory, or, with the image at hand, read
    /// from it. A record is registered only once the image had its row, so
    /// a miss leaves nothing behind.
    private func resolve(_ type: TypeID, _ id: String, _ disk: Disk?, _ batch: inout Batch) -> Record? {
        let typeName = type.name
        let key = Record.entityKey(typeName, id)
        if let record = records[key] { return record.deleted ? nil : record }
        guard let disk else { return nil }
        let candidate = Record(type: type, key: key, idOffset: Record.idOffset(ofType: typeName))
        guard hydrate(candidate, from: disk, &batch) else { return nil }
        records[key] = candidate
        return candidate.deleted ? nil : candidate
    }

    /// The one live entity with this id among the named types. None, or an
    /// id more than one of them has, is no record; the second is reported.
    private func entity(id: String, among typeNames: [String]) -> Record? {
        let found = live(id: id, among: typeNames)
        guard found.count == 1 else {
            if found.count > 1 { log?(.ambiguousIdentity(id: id, types: found.map(\.type.name))) }
            return nil
        }
        return found[0]
    }
}
