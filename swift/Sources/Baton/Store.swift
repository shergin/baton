import Observation

/// The normalized records, on the main actor. Reads are synchronous; commits
/// are atomic batches that notify only the observed fields that changed.
@MainActor
public final class Store {
    nonisolated public static let rootKey = "client:root"

    /// The record root fields hang off.
    public let root: Record
    private var records: [String: Record] = [:]

    /// Called when a lens reads a slot the store never received. Debug builds
    /// print by default; a product can route it to its own reporting.
    public var reportMissing: ((Record, Slot) -> Void)?

    /// Bumped by `invalidate()`; handles fetched before it are stale.
    public private(set) var invalidationEpoch = 0

    /// Marks everything fetched so far as stale.
    public func invalidate() { invalidationEpoch += 1 }

    public init(rootType: TypeID = Registry.type("Query")) {
        root = Record(type: rootType, key: Store.rootKey)
        records[Store.rootKey] = root
        #if DEBUG
        reportMissing = { record, slot in
            print("Baton: missing data: \(record.key).\(slot.storageKey) was read but never fetched; the owning operation will refetch")
        }
        #endif
    }

    public var count: Int { records.count }

    public func existing(_ key: String) -> Record? { records[key] }

    func record(key: String, type: TypeID) -> Record {
        if let record = records[key] { return record }
        let record = Record(type: type, key: key)
        records[key] = record
        return record
    }

    /// Applies a change set: last write wins per (record, slot); a value equal
    /// to the slot's current value is neither allocated nor notified.
    /// Returns the number of slots that changed.
    @discardableResult
    public func commit(_ changes: ChangeSet) -> Int {
        // Materialize record objects first so references can be resolved.
        var objects = ContiguousArray<Record>()
        objects.reserveCapacity(changes.recordKeys.count)
        for index in 0..<changes.recordKeys.count {
            objects.append(record(key: changes.recordKeys[index], type: changes.recordTypes[index]))
        }

        // Last entry wins per (record, slot).
        var offsets = [Int](repeating: 0, count: objects.count + 1)
        for index in 0..<objects.count {
            offsets[index + 1] = offsets[index] + Registry.slotCount(changes.recordTypes[index])
        }
        var winners = [Int32](repeating: -1, count: offsets[objects.count])
        for (position, entry) in changes.entries.enumerated() {
            winners[offsets[Int(entry.record)] + Int(entry.slot.index)] = Int32(position)
        }

        var changed = 0
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
                if record.write(entry.slot, value) { changed += 1 }
            }
        }
        return changed
    }

    /// Whether every field of the selection is present, starting at `record`.
    /// A missing root link with a lookup is satisfied by the cached entity,
    /// and the link is written so later reads are direct.
    public func check(_ selection: ResolvedSelection, at record: Record? = nil) -> Bool {
        let record = record ?? root
        for field in selection.fields {
            switch field.kind {
            case .scalar:
                if case .missing = record.peek(field.slot) { return false }
            case .linked(let child, let plural, let lookupKey):
                switch record.peek(field.slot) {
                case .missing:
                    guard !plural, let (_, key) = lookupKey, let target = records[key] else { return false }
                    guard check(child, at: target) else { return false }
                    record.write(field.slot, .ref(target))
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
        for field in selection.fields {
            guard case .linked(let child, _, _) = field.kind else { continue }
            switch record.peek(field.slot) {
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

    /// Removes every record not in `reachable` (the root stays), clears their
    /// slots so cycles break, and drops the root's links to them. Returns how
    /// many records were removed.
    @discardableResult
    func sweep(keeping reachable: Set<ObjectIdentifier>) -> Int {
        var swept = Set<ObjectIdentifier>()
        for (key, record) in records where key != Store.rootKey && !reachable.contains(ObjectIdentifier(record)) {
            swept.insert(ObjectIdentifier(record))
            records.removeValue(forKey: key)
            record.clear()
        }
        if !swept.isEmpty { root.prune(swept) }
        return swept.count
    }

    /// Resolves a lookup for a lens read: the cached entity for a root field
    /// that was never fetched, written back as the link.
    func resolveLookup(on record: Record, slot: Slot, lookup: Lookup, variables: Variables) -> Record? {
        let value = switch lookup.key {
        case .variable(let name): variables.keyText(name)
        case .literal(let text): text
        }
        guard let target = records[lookup.type.name + ":" + value] else { return nil }
        record.write(slot, .ref(target))
        return target
    }
}
