import Foundation
import Observation

/// The normalized records, on the main actor. Reads are synchronous; commits
/// are atomic batches that notify only the observed fields that changed.
/// Optimistic layers sit on top of the server's truth and rebase under it.
@MainActor
public final class Store {
    nonisolated public static let rootKey = "client:root"
    nonisolated public static let mutationRootKey = "client:root:mutation"

    /// The record query root fields hang off.
    public let root: Record
    /// The record mutation payloads hang off; their entities merge as usual.
    public let mutationRoot: Record
    private var records: [String: Record] = [:]
    /// Entities by id, across types, for `node(id:)`-style lookups.
    private var byID: [String: Record] = [:]

    /// Called when a lens reads a slot the store never received. Debug builds
    /// print by default; a product can route it to its own reporting.
    public var reportMissing: ((Record, Slot) -> Void)?

    /// Bumped by `invalidate()`; handles fetched before it are stale.
    public private(set) var invalidationEpoch = 0

    /// Optimistic responses currently applied, oldest first.
    public private(set) var optimisticLayers: [OptimisticLayer] = []

    public init(rootType: TypeID = Registry.type("Query"), mutationType: TypeID = Registry.type("Mutation")) {
        root = Record(type: rootType, key: Store.rootKey)
        mutationRoot = Record(type: mutationType, key: Store.mutationRootKey)
        records[Store.rootKey] = root
        records[Store.mutationRootKey] = mutationRoot
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

    /// The entity with this id, whatever its type.
    public func existing(id: String) -> Record? { byID[id] }

    func record(key: String, type: TypeID) -> Record {
        if let record = records[key] { return record }
        let record = Record(type: type, key: key)
        records[key] = record
        if !key.hasPrefix("client:"), let colon = key.firstIndex(of: ":") {
            byID[String(key[key.index(after: colon)...])] = record
        }
        return record
    }

    // MARK: Commits and optimistic layers

    /// A pending optimistic response: its change set, and what it overwrote.
    public struct OptimisticLayer: Identifiable, Sendable {
        public let id: UUID
        public let changes: ChangeSet
        var undo: [Undo] = []
    }

    struct Undo: @unchecked Sendable {
        let record: Record
        let slot: Slot
        let value: Value
    }

    /// Tracks every slot a batch touched and its value before the batch, so
    /// the batch can notify only the slots whose value differs at the end.
    @MainActor
    private struct Transaction {
        /// A plain commit with no layers notifies as it writes; nothing can
        /// change back within the batch, so there is nothing to net out.
        private let direct: Bool
        private var directCount = 0
        private var originals: [SlotKey: Undo] = [:]

        private struct SlotKey: Hashable {
            let record: ObjectIdentifier
            let slot: Slot
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
            if originals[key] == nil { originals[key] = Undo(record: record, slot: slot, value: before) }
        }

        /// Notifies changed slots; returns how many changed.
        func finish() -> Int {
            if direct { return directCount }
            var changed = 0
            for undo in originals.values where undo.record.peek(undo.slot) != undo.value {
                undo.record.notify(undo.slot)
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
            _ = apply(changes, into: &transaction)
            return transaction.finish()
        }
        var transaction = Transaction()
        revertLayers(from: 0, into: &transaction)
        _ = apply(changes, into: &transaction)
        reapplyLayers(from: 0, into: &transaction)
        return transaction.finish()
    }

    /// Applies an optimistic response on top of everything else.
    public func applyOptimistic(_ changes: ChangeSet) -> UUID {
        var transaction = Transaction()
        var layer = OptimisticLayer(id: UUID(), changes: changes)
        layer.undo = apply(changes, into: &transaction)
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
        _ = apply(changes, into: &transaction)
        reapplyLayers(from: 0, into: &transaction)
        return transaction.finish()
    }

    private func revertLayers(from index: Int, into transaction: inout Transaction) {
        for layer in optimisticLayers[index...].reversed() {
            for undo in layer.undo.reversed() {
                if let previous = undo.record.writeSilently(undo.slot, undo.value) {
                    transaction.touched(undo.record, undo.slot, before: previous)
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
    }

    /// Writes a change set silently: last entry wins per (record, slot); a
    /// value equal to the slot's current value is neither allocated nor
    /// recorded. Returns the undo log of the slots that changed.
    private func apply(_ changes: ChangeSet, into transaction: inout Transaction) -> [Undo] {
        var objects = ContiguousArray<Record>()
        objects.reserveCapacity(changes.recordKeys.count)
        for index in 0..<changes.recordKeys.count {
            objects.append(record(key: changes.recordKeys[index], type: changes.recordTypes[index]))
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
                if let previous = record.writeSilently(entry.slot, value) {
                    transaction.touched(record, entry.slot, before: previous)
                    undo.append(Undo(record: record, slot: entry.slot, value: previous))
                }
            }
        }
        return undo
    }

    // MARK: Availability, marking, sweeping

    /// Whether every field of the selection is present, starting at `record`.
    /// A missing root link with a lookup is satisfied by the cached entity,
    /// and the link is written so later reads are direct.
    public func check(_ selection: ResolvedSelection, at record: Record? = nil) -> Bool {
        let record = record ?? root
        let fields = selection.fields
        for index in fields.indices {
            if fields[index].isTypename { continue }
            let slot = selection.isAbstract ? selection.slots(for: record.type)[index] : fields[index].slot
            switch fields[index].kind {
            case .scalar:
                if case .missing = record.peek(slot) { return false }
            case .linked(let child, let plural, let lookupKey):
                switch record.peek(slot) {
                case .missing:
                    guard !plural, let lookupKey, let target = resolve(lookupKey) else { return false }
                    guard check(child, at: target) else { return false }
                    record.write(slot, .ref(target))
                case .null:
                    continue
                case .ref(let target):
                    if !check(child, at: target) { return false }
                case .refs(let targets):
                    for case let target? in targets where !check(child, at: target) { return false }
                default:
                    return false
                }
            }
        }
        return true
    }

    /// Collects every record the selection reaches from the root, for collection.
    func mark(_ selection: ResolvedSelection, from record: Record? = nil, into reachable: inout Set<ObjectIdentifier>) {
        let record = record ?? root
        reachable.insert(ObjectIdentifier(record))
        let fields = selection.fields
        for index in fields.indices {
            guard case .linked(let child, _, _) = fields[index].kind else { continue }
            let slot = selection.isAbstract ? selection.slots(for: record.type)[index] : fields[index].slot
            switch record.peek(slot) {
            case .ref(let target):
                mark(child, from: target, into: &reachable)
            case .refs(let targets):
                for case let target? in targets {
                    mark(child, from: target, into: &reachable)
                }
            default:
                continue
            }
        }
    }

    /// Removes every record not in `reachable` (the roots stay), clears their
    /// slots so cycles break, and drops the roots' links to them. Returns how
    /// many records were removed.
    @discardableResult
    func sweep(keeping reachable: Set<ObjectIdentifier>) -> Int {
        var swept = Set<ObjectIdentifier>()
        for (key, record) in records
        where key != Store.rootKey && key != Store.mutationRootKey && !reachable.contains(ObjectIdentifier(record)) {
            swept.insert(ObjectIdentifier(record))
            records.removeValue(forKey: key)
            if !key.hasPrefix("client:"), let colon = key.firstIndex(of: ":") {
                byID.removeValue(forKey: String(key[key.index(after: colon)...]))
            }
            record.clear()
        }
        if !swept.isEmpty {
            root.prune(swept)
            mutationRoot.prune(swept)
        }
        return swept.count
    }

    /// The entity a lookup names, if cached.
    func resolve(_ lookup: LookupKey) -> Record? {
        if let key = lookup.recordKey { return records[key] }
        return byID[lookup.value]
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
