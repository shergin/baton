import Foundation
import Observation

/// The normalized records, on the main actor. Reads are synchronous; commits
/// are atomic batches that notify only the observed fields that changed.
/// Optimistic layers sit on top of the server's truth and rebase under it.
@MainActor
public final class Store {
    nonisolated public static let rootKey = "client:root"
    nonisolated public static let mutationRootKey = "client:root:mutation"
    nonisolated public static let subscriptionRootKey = "client:root:subscription"

    /// The record query root fields hang off.
    public let root: Record
    /// The record mutation payloads hang off; their entities merge as usual.
    public let mutationRoot: Record
    /// The record subscription payloads hang off.
    public let subscriptionRoot: Record
    private var records: [String: Record] = [:]
    /// Entities by id, across types, for `node(id:)`-style lookups.
    private var byID: [String: Record] = [:]
    /// The environment that owns the store, for lenses that fetch.
    weak var environment: Environment?

    /// Called when a lens reads a slot the store never received. Debug builds
    /// print by default; a product can route it to its own reporting.
    public var reportMissing: ((Record, Slot) -> Void)?

    /// Bumped by `invalidate()`; handles fetched before it are stale.
    public private(set) var invalidationEpoch = 0

    /// Optimistic responses currently applied, oldest first.
    public private(set) var optimisticLayers: [OptimisticLayer] = []

    /// The store's image on disk, when it has one: every commit is written
    /// behind, and the availability check reads from it what memory lacks.
    public let persistence: Persistence?
    /// How many records have been filled from the image.
    public internal(set) var hydratedRecords = 0
    /// Fields whose error a batch set or cleared. An error can change while
    /// the value stays null, so the undo log does not show it and the image
    /// needs to be told.
    private var errorTouched: [(record: Record, slot: Slot)] = []
    /// The image's connection while a check is reading from it.
    private var reading: Disk?

    public init(
        rootType: TypeID = Registry.type("Query"),
        mutationType: TypeID = Registry.type("Mutation"),
        subscriptionType: TypeID = Registry.type("Subscription"),
        persistence: Persistence? = nil
    ) {
        self.persistence = persistence
        root = Record(type: rootType, key: Store.rootKey)
        mutationRoot = Record(type: mutationType, key: Store.mutationRootKey)
        subscriptionRoot = Record(type: subscriptionType, key: Store.subscriptionRootKey)
        records[Store.rootKey] = root
        records[Store.mutationRootKey] = mutationRoot
        records[Store.subscriptionRootKey] = subscriptionRoot
        #if DEBUG
        reportMissing = { record, slot in
            print("Baton: missing data: \(record.key).\(slot.storageKey) was read but never fetched; the owning operation will refetch")
        }
        #endif
    }

    /// Marks everything fetched so far as stale.
    public func invalidate() { invalidationEpoch += 1 }

    public var count: Int { records.count }

    public func existing(_ key: String) -> Record? { records[key] }

    /// Every record the store holds, by key; for the store dumps under `spec/`.
    package var recordsByKey: [String: Record] { records }

    /// The entity with this id, whatever its type.
    public func existing(id: String) -> Record? { byID[id] }

    /// The record for a key, created on first sight. An entity is indexed by
    /// its id; a deleted record a payload names again comes back.
    func record(key: String, type: TypeID, entity: Bool) -> Record {
        record(key: key, type: type, entity: entity).record
    }

    /// The record for a key, and whether this call created it.
    private func record(key: String, type: TypeID, entity: Bool) -> (record: Record, created: Bool) {
        if let record = records[key] {
            if record.deleted {
                record.setDeleted(false)
                record.notifyAll()
            }
            return (record, false)
        }
        let id = entity ? String(key.dropFirst(type.name.count + 1)) : nil
        let record = Record(type: type, key: key, entityID: id)
        records[key] = record
        if let id { byID[id] = record }
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
    public struct OptimisticLayer: Identifiable, Sendable {
        public let id: UUID
        public let changes: ChangeSet
        var undo: [Undo] = []
    }

    /// One step of a batch, reversed when a layer lifts.
    enum Undo: @unchecked Sendable {
        case slot(Record, Slot, Value)
        /// The batch deleted the record; lifting it revives the record.
        case deleted(Record)
    }

    /// Tracks every slot a batch touched and its value before the batch, so
    /// the batch can notify only the slots whose value differs at the end.
    @MainActor
    private struct Transaction {
        /// A plain commit with no layers notifies as it writes; nothing can
        /// change back within the batch, so there is nothing to net out.
        private let direct: Bool
        private var directCount = 0
        private var originals: [SlotKey: Original] = [:]

        private struct SlotKey: Hashable {
            let record: ObjectIdentifier
            let slot: Slot
        }

        private struct Original {
            let record: Record
            let slot: Slot
            let value: Value
        }

        init(direct: Bool = false) {
            self.direct = direct
        }

        mutating func touched(_ record: Record, _ slot: Slot, before: Value) {
            if direct {
                record.notify(slot)
                directCount += 1
                return
            }
            let key = SlotKey(record: ObjectIdentifier(record), slot: slot)
            if originals[key] == nil { originals[key] = Original(record: record, slot: slot, value: before) }
        }

        /// Notifies changed slots; returns how many changed.
        func finish() -> Int {
            if direct { return directCount }
            var changed = 0
            for original in originals.values where original.record.peek(original.slot) != original.value {
                original.record.notify(original.slot)
                changed += 1
            }
            return changed
        }
    }

    /// Applies a change set from the server. Under optimistic layers, the
    /// layers are lifted, the payload applied, and the layers re-applied, and
    /// only the net difference is notified. Returns the number of slots that
    /// changed.
    @discardableResult
    public func commit(_ changes: ChangeSet) -> Int {
        if optimisticLayers.isEmpty {
            var transaction = Transaction(direct: true)
            persist(apply(changes, into: &transaction))
            return transaction.finish()
        }
        var transaction = Transaction()
        revertLayers(from: 0, into: &transaction)
        persist(apply(changes, into: &transaction))
        reapplyLayers(from: 0, into: &transaction)
        return transaction.finish()
    }

    /// Hands the image what a server's payload changed: a snapshot of every
    /// changed record, and the changed fields of the root one by one. Called
    /// while the optimistic layers are lifted, so the values are the server's.
    private func persist(_ undo: [Undo]) {
        guard let persistence else { return }
        defer { errorTouched.removeAll(keepingCapacity: true) }
        if undo.isEmpty, errorTouched.isEmpty { return }
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
            case .slot(let record, let slot, _):
                if record === root {
                    fields.append(Persistence.RootField(slot: slot, value: root.peek(slot), error: root.peekError(slot)))
                } else {
                    add(record)
                }
            case .deleted(let record):
                add(record)
            }
        }
        for (record, slot) in errorTouched {
            if record === root {
                fields.append(Persistence.RootField(slot: slot, value: root.peek(slot), error: root.peekError(slot)))
            } else {
                add(record)
            }
        }
        if records.isEmpty, fields.isEmpty { return }
        persistence.committed(records, root: fields)
    }

    /// Applies an optimistic response on top of everything else.
    public func applyOptimistic(_ changes: ChangeSet) -> UUID {
        var transaction = Transaction()
        var layer = OptimisticLayer(id: UUID(), changes: changes)
        layer.undo = apply(changes, into: &transaction)
        errorTouched.removeAll(keepingCapacity: true)
        optimisticLayers.append(layer)
        _ = transaction.finish()
        return layer.id
    }

    /// Removes an optimistic layer; later layers are re-applied over the gap.
    public func revertOptimistic(_ id: UUID) {
        guard let index = optimisticLayers.firstIndex(where: { $0.id == id }) else { return }
        var transaction = Transaction()
        revertLayers(from: index, into: &transaction)
        optimisticLayers.remove(at: index)
        reapplyLayers(from: index, into: &transaction)
        _ = transaction.finish()
    }

    /// Commits the server's answer to an optimistic mutation: the layer is
    /// replaced by the payload in one batch.
    @discardableResult
    public func commit(_ changes: ChangeSet, replacingOptimistic id: UUID) -> Int {
        var transaction = Transaction()
        revertLayers(from: 0, into: &transaction)
        optimisticLayers.removeAll { $0.id == id }
        persist(apply(changes, into: &transaction))
        reapplyLayers(from: 0, into: &transaction)
        return transaction.finish()
    }

    private func revertLayers(from index: Int, into transaction: inout Transaction) {
        for layer in optimisticLayers[index...].reversed() {
            for undo in layer.undo.reversed() {
                switch undo {
                case .slot(let record, let slot, let value):
                    if let previous = record.writeSilently(slot, value) {
                        transaction.touched(record, slot, before: previous)
                    }
                case .deleted(let record):
                    record.setDeleted(false)
                    record.notifyAll()
                }
            }
        }
        for position in index..<optimisticLayers.count {
            optimisticLayers[position].undo.removeAll()
        }
    }

    private func reapplyLayers(from index: Int, into transaction: inout Transaction) {
        for position in index..<optimisticLayers.count {
            optimisticLayers[position].undo = apply(optimisticLayers[position].changes, into: &transaction)
        }
        // An optimistic response is never written to the image.
        errorTouched.removeAll(keepingCapacity: true)
    }

    /// Writes one slot inside a batch: silently, recorded for the net
    /// notification and for the undo log.
    private func set(_ record: Record, _ slot: Slot, _ value: Value, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        if let previous = record.writeSilently(slot, value) {
            transaction.touched(record, slot, before: previous)
            undo.append(.slot(record, slot, previous))
        }
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

        var offsets = [Int](repeating: 0, count: objects.count + 1)
        for index in 0..<objects.count {
            offsets[index + 1] = offsets[index] + Registry.slotCount(changes.recordTypes[index])
        }
        var winners = [Int32](repeating: -1, count: offsets[objects.count])
        for (position, entry) in changes.entries.enumerated() {
            winners[offsets[Int(entry.record)] + Int(entry.slot.index)] = Int32(position)
        }

        var undo: [Undo] = []
        for index in 0..<objects.count {
            let record = objects[index]
            if created[index] {
                // A new record makes room once, for the highest slot it receives.
                var highest = offsets[index + 1] - 1
                while highest >= offsets[index], winners[highest] < 0 { highest -= 1 }
                if highest >= offsets[index] { record.reserve(highest - offsets[index] + 1) }
            }
            for position in offsets[index]..<offsets[index + 1] {
                let winner = winners[position]
                if winner < 0 { continue }
                let entry = changes.entries[Int(winner)]
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
                    var list = ContiguousArray<Record?>()
                    list.reserveCapacity(Int(count))
                    for offset in 0..<Int(count) {
                        let target = changes.refs[Int(start) + offset]
                        list.append(target < 0 ? nil : objects[Int(target)])
                    }
                    value = .refs(list)
                case .list(let start, let count):
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
                set(record, entry.slot, value, &transaction, &undo)
                if record.hasErrors, record.setError(entry.slot, nil) {
                    record.notify(entry.slot)
                    if persistence != nil { errorTouched.append((record, entry.slot)) }
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
                guard let node = byID[id] else { continue }
                for key in connections {
                    deleteEdges(of: node, from: key, &transaction, &undo)
                }
            case .deleteRecord(let id):
                guard let record = byID[id], !record.deleted else { continue }
                delete(record, &transaction, &undo)
            }
        }

        // Field errors land beside the field; an error arriving counts as a
        // change of the slot. They are not part of the undo log: optimistic
        // responses carry none.
        for entry in changes.fieldErrors {
            let record = objects[Int(entry.record)]
            if record.setError(entry.slot, entry.error) {
                record.notify(entry.slot)
                if persistence != nil { errorTouched.append((record, entry.slot)) }
            }
        }
        return undo
    }

    // MARK: Connections

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
        for index in 0..<page.slotCount where index != Int(slots.edges.index) && index != Int(slots.pageInfoLink.index) {
            let value = page.peek(index: index)
            if case .missing = value { continue }
            set(connection, Slot(type: slots.connection, index: Int32(index)), value, &transaction, &undo)
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

    /// Inserts a copy of a payload's edge into a connection named by id, unless
    /// an edge for the same node is already there. The copy is the
    /// connection's own record, as in Relay: the payload's edge record is
    /// keyed by its path, so the next mutation of the same kind would alias it.
    private func insert(edge: Record, into connectionKey: String, prepend: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard let connection = records[connectionKey], !connection.deleted else { return }
        if contains(connection, node: Store.node(of: edge, Registry.slot(edge.type, "node"))) { return }
        let copy = ownEdge(of: connection, type: edge.type, &transaction, &undo)
        for index in 0..<edge.slotCount {
            let value = edge.peek(index: index)
            if case .missing = value { continue }
            set(copy, Slot(type: edge.type, index: Int32(index)), value, &transaction, &undo)
        }
        append(copy, to: connection, prepend: prepend, &transaction, &undo)
    }

    /// Wraps a node in a new edge record of the connection and inserts it.
    private func insert(node: Record, edgeType: TypeID, into connectionKey: String, prepend: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard let connection = records[connectionKey], !connection.deleted else { return }
        if contains(connection, node: ObjectIdentifier(node)) { return }
        let edge = ownEdge(of: connection, type: edgeType, &transaction, &undo)
        set(edge, Registry.slot(edgeType, "node"), .ref(node), &transaction, &undo)
        set(edge, Registry.slot(edgeType, "cursor"), .null, &transaction, &undo)
        append(edge, to: connection, prepend: prepend, &transaction, &undo)
    }

    /// A new edge record owned by the connection, numbered by Relay's
    /// `__connection_next_edge_index` client field.
    private func ownEdge(of connection: Record, type: TypeID, _ transaction: inout Transaction, _ undo: inout [Undo]) -> Record {
        let indexSlot = Registry.slot(connection.type, "__connection_next_edge_index")
        let index: Int = if case .int(let index) = connection.peek(indexSlot) { index } else { 0 }
        set(connection, indexSlot, .int(index + 1), &transaction, &undo)
        return record(key: connection.key + ":edges:" + String(index), type: type, entity: false)
    }

    private func contains(_ connection: Record, node: ObjectIdentifier?) -> Bool {
        guard let node else { return false }
        for case let edge? in Store.edges(connection, Registry.slot(connection.type, "edges"))
        where Store.node(of: edge, Registry.slot(edge.type, "node")) == node {
            return true
        }
        return false
    }

    private func append(_ edge: Record, to connection: Record, prepend: Bool, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        let edgesSlot = Registry.slot(connection.type, "edges")
        var edges = Store.edges(connection, edgesSlot)
        if prepend { edges.insert(edge, at: 0) } else { edges.append(edge) }
        set(connection, edgesSlot, .refs(edges), &transaction, &undo)
    }

    /// Removes every edge whose node is the record from a connection named by id.
    private func deleteEdges(of node: Record, from connectionKey: String, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        guard let connection = records[connectionKey], !connection.deleted else { return }
        let edgesSlot = Registry.slot(connection.type, "edges")
        let edges = Store.edges(connection, edgesSlot)
        let target = ObjectIdentifier(node)
        let kept = edges.filter { edge in
            guard let edge else { return true }
            return Store.node(of: edge, Registry.slot(edge.type, "node")) != target
        }
        if kept.count == edges.count { return }
        set(connection, edgesSlot, .refs(ContiguousArray(kept)), &transaction, &undo)
    }

    /// Deletes a record: its values are cleared through the undo log, it is
    /// marked deleted so links to it read as null, and every observer of it
    /// is notified.
    private func delete(_ record: Record, _ transaction: inout Transaction, _ undo: inout [Undo]) {
        for index in 0..<record.slotCount {
            let value = record.peek(index: index)
            if case .missing = value { continue }
            set(record, Slot(type: record.type, index: Int32(index)), .missing, &transaction, &undo)
        }
        record.setDeleted(true)
        record.notifyAll()
        undo.append(.deleted(record))
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
    public func check(_ selection: ResolvedSelection, at record: Record? = nil) -> Bool {
        let record = record ?? root
        if holds(selection, at: record) { return true }
        // A check an observer starts while the image is being read joins
        // the read that is open.
        if let reading { return fill(selection, at: record, from: reading) }
        guard let persistence else { return false }
        return persistence.reading { disk in
            reading = disk
            defer { reading = nil }
            return fill(selection, at: record, from: disk)
        }
    }

    /// The walk in memory: whether the store holds every field as it stands.
    private func holds(_ selection: ResolvedSelection, at record: Record) -> Bool {
        let fields = selection.fields
        for index in fields.indices {
            if fields[index].isTypename || fields[index].deferred != nil { continue }
            let slot = selection.slot(of: index, on: record.type)
            switch fields[index].kind {
            case .scalar:
                if case .missing = record.peek(slot) { return false }
            case .linked(let child, let plural, let lookupKey, _):
                switch record.peek(slot) {
                case .missing:
                    guard !plural, let lookupKey, let target = resolve(lookupKey) else { return false }
                    guard holds(child, at: target) else { return false }
                    record.write(slot, .ref(target))
                case .null:
                    continue
                case .ref(let target):
                    if target.deleted { continue }
                    if !holds(child, at: target) { return false }
                case .refs(let targets):
                    for case let target? in targets where !target.deleted && !holds(child, at: target) { return false }
                default:
                    return false
                }
            }
        }
        return true
    }

    /// The same walk with the image at hand. A record that lacks a field
    /// reads its row first; a link to a record the collector swept is pointed
    /// at the live record of that key; a connection's client record is walked
    /// while it is still unread.
    private func fill(_ selection: ResolvedSelection, at record: Record, from disk: Disk) -> Bool {
        let fields = selection.fields
        for index in fields.indices {
            if fields[index].isTypename || fields[index].deferred != nil { continue }
            let slot = selection.slot(of: index, on: record.type)
            if case .missing = record.peek(slot) { hydrate(record, slot, from: disk) }
            switch fields[index].kind {
            case .scalar:
                if case .missing = record.peek(slot) { return false }
            case .linked(let child, let plural, let lookupKey, let connection):
                switch record.peek(slot) {
                case .missing:
                    guard !plural, let lookupKey, let target = resolve(lookupKey, disk) else { return false }
                    guard fill(child, at: target, from: disk) else { return false }
                    record.write(slot, .ref(target))
                case .null:
                    break
                case .ref(let found):
                    let target = live(found, disk)
                    if target !== found { record.write(slot, .ref(target)) }
                    if !target.deleted, !fill(child, at: target, from: disk) { return false }
                case .refs(var targets):
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
                    for case let target? in targets where !target.deleted && !fill(child, at: target, from: disk) { return false }
                default:
                    return false
                }
                // Lenses read a connection through its client record, which
                // the walk above does not pass. One the image has yet to fill
                // is walked here, so its merged pages come back with it.
                if let connection, case .ref(let found) = record.peek(selection.slot(of: connection, on: record.type)) {
                    let unread = found.swept || (!found.hydrated && found.slotCount == 0)
                    let merged = live(found, disk)
                    if merged !== found { record.write(selection.slot(of: connection, on: record.type), .ref(merged)) }
                    if unread, !merged.deleted, !fill(child, at: merged, from: disk) { return false }
                }
            }
        }
        return true
    }

    /// A link's target as the store and the image know it together: the live
    /// record of the key when the collector swept the one the link holds,
    /// and, for a record that holds nothing yet, its row, so that whether it
    /// was deleted is known before the walk decides to enter it.
    private func live(_ found: Record, _ disk: Disk) -> Record {
        let record = found.swept ? target(key: found.key, type: found.type, entity: found.entityID != nil) : found
        if !record.hydrated, record.slotCount == 0, record !== root, record !== mutationRoot, record !== subscriptionRoot {
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
        let fields = selection.fields
        for index in fields.indices {
            guard case .linked(let child, _, _, let connection) = fields[index].kind else { continue }
            mark(record.peek(selection.slot(of: index, on: record.type)), child, into: &reachable)
            if let connection {
                mark(record.peek(selection.slot(of: connection, on: record.type)), child, into: &reachable)
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
        var swept = Set<ObjectIdentifier>()
        for (key, record) in records
        where key != Store.rootKey && key != Store.mutationRootKey && key != Store.subscriptionRootKey && !reachable.contains(ObjectIdentifier(record)) {
            swept.insert(ObjectIdentifier(record))
            records.removeValue(forKey: key)
            if let id = record.entityID, byID[id] === record {
                byID.removeValue(forKey: id)
            }
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
            guard case .name(let name) = segment, let index = selection.field(named: name),
                  case .linked(let child, _, _, _) = selection.fields[index].kind
            else { return nil }
            switch record.peek(selection.slot(of: index, on: record.type)) {
            case .ref(let target):
                record = target
            case .refs(let targets):
                guard case .index(let offset)? = segments.popFirst(), offset < targets.count, let target = targets[offset] else { return nil }
                record = target
            default:
                return nil
            }
            selection = child
        }
        return (record, selection)
    }

    /// The entity a lookup names, if cached and not deleted. With the image
    /// at hand, an entity only the image holds counts when its type is known.
    func resolve(_ lookup: LookupKey, _ disk: Disk? = nil) -> Record? {
        var record = lookup.recordKey.map { records[$0] } ?? byID[lookup.value]
        if record == nil, let disk, let type = lookup.type, let key = lookup.recordKey {
            let candidate = target(key: key, type: type, entity: true)
            if hydrate(candidate, from: disk) { record = candidate }
        }
        guard let record, !record.deleted else { return nil }
        return record
    }

    /// Resolves a lookup for a lens read: the cached entity for a root field
    /// that was never fetched, written back as the link.
    func resolveLookup(on record: Record, slot: Slot, lookup: Lookup, variables: Variables) -> Record? {
        let value = switch lookup.key {
        case .variable(let name): variables.keyText(name)
        case .literal(let text): text
        }
        guard let target = resolve(LookupKey(type: lookup.type, value: value)) else { return nil }
        record.write(slot, .ref(target))
        return target
    }
}
