import SwiftUI

/// Where a lens reads from: one record, the variables that bind any
/// argument-carrying storage key along its path, and the record it was
/// reached from, which a connection needs for the owner's id.
public struct Anchor: @unchecked Sendable {
    public let record: Record
    public let variables: Variables
    let store: Store?
    let parent: Record?

    public init(record: Record, variables: Variables, store: Store? = nil, parent: Record? = nil) {
        self.record = record
        self.variables = variables
        self.store = store
        self.parent = parent
    }

    func child(_ record: Record) -> Anchor {
        Anchor(record: record, variables: variables, store: store, parent: self.record)
    }

    /// The same record under a fragment's scope: the parent's variables with
    /// the fragment's arguments bound over them, as Relay's fragment variables.
    public func binding(_ values: [String: Variable?]) -> Anchor {
        var merged = variables.values
        for (name, value) in values { merged[name] = value ?? .null }
        return Anchor(record: record, variables: Variables(merged), store: store, parent: parent)
    }
}

/// A typed, read-only view over one record: a fragment's or an operation's
/// data. The compiler generates one struct per selection; this protocol is
/// what they share. The static checks are generated where a directive asks
/// for them and default to the permissive answer elsewhere.
public protocol Lens: Sendable {
    var anchor: Anchor { get }
    init(anchor: Anchor)
    static var typeName: String { get }
    /// Whether every `@required` field of the selection is present.
    @MainActor static func satisfied(_ anchor: Anchor) -> Bool
    /// The field errors in the selection, for `@catch` and `@throwOnFieldError`.
    @MainActor static func fieldErrors(_ anchor: Anchor) -> [FieldError]
    /// Whether a deferred fragment's fields have arrived.
    @MainActor static func isPresent(_ anchor: Anchor) -> Bool
}

extension Lens {
    /// The record's identity, for list diffing.
    @MainActor public var recordID: RecordID { RecordID(anchor.record) }

    @MainActor public static func satisfied(_ anchor: Anchor) -> Bool { true }
    @MainActor public static func fieldErrors(_ anchor: Anchor) -> [FieldError] { [] }
    @MainActor public static func isPresent(_ anchor: Anchor) -> Bool { true }
}

@MainActor
extension Anchor {
    private func missing(_ slot: Slot) {
        anchor.store?.reportMissing?(record, slot)
    }

    private var anchor: Anchor { self }

    /// The slot of a storage key on the record's own type, for selections on
    /// interfaces and unions.
    @inline(__always) public func slot(key: String) -> Slot { Registry.slot(record.type, key) }

    public func string(_ slot: Slot) -> String? {
        switch record.read(slot) {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return bool ? "true" : "false"
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    public func requiredString(_ slot: Slot) -> String { string(slot) ?? "" }

    public func int(_ slot: Slot) -> Int? {
        switch record.read(slot) {
        case .int(let int): return int
        case .double(let double): return Int(exactly: double)
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    public func requiredInt(_ slot: Slot) -> Int { int(slot) ?? 0 }

    public func double(_ slot: Slot) -> Double? {
        switch record.read(slot) {
        case .double(let double): return double
        case .int(let int): return Double(int)
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    public func requiredDouble(_ slot: Slot) -> Double { double(slot) ?? 0 }

    public func bool(_ slot: Slot) -> Bool? {
        switch record.read(slot) {
        case .bool(let bool): return bool
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    public func requiredBool(_ slot: Slot) -> Bool { bool(slot) ?? false }

    public func strings(_ slot: Slot) -> [String]? { scalars(slot) { if case .string(let string) = $0 { string } else { nil } } }
    public func requiredStrings(_ slot: Slot) -> [String] { strings(slot) ?? [] }
    public func ints(_ slot: Slot) -> [Int]? { scalars(slot) { if case .int(let int) = $0 { int } else { nil } } }
    public func requiredInts(_ slot: Slot) -> [Int] { ints(slot) ?? [] }
    public func doubles(_ slot: Slot) -> [Double]? { scalars(slot) { if case .double(let double) = $0 { double } else { nil } } }
    public func requiredDoubles(_ slot: Slot) -> [Double] { doubles(slot) ?? [] }
    public func bools(_ slot: Slot) -> [Bool]? { scalars(slot) { if case .bool(let bool) = $0 { bool } else { nil } } }
    public func requiredBools(_ slot: Slot) -> [Bool] { bools(slot) ?? [] }

    private func scalars<T>(_ slot: Slot, _ transform: (Value) -> T?) -> [T]? {
        switch record.read(slot) {
        case .list(let values): return values.compactMap(transform)
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    /// The record behind a singular link, resolving a lookup when the link was
    /// never fetched but the entity is cached. A deleted record reads as null.
    public func linked(_ slot: Slot, lookup: Lookup? = nil) -> Anchor? {
        switch record.read(slot) {
        case .ref(let target): return target.deleted ? nil : child(target)
        case .missing:
            if let lookup, let store, let target = store.resolveLookup(on: record, slot: slot, lookup: lookup, variables: variables) {
                return child(target)
            }
            missing(slot)
            return nil
        default: return nil
        }
    }

    /// A non-null link. When the data is missing, a detached empty record of the
    /// expected type stands in so reads yield zero values, and the miss is reported.
    public func requiredLinked(_ slot: Slot, type: TypeID, lookup: Lookup? = nil) -> Anchor {
        linked(slot, lookup: lookup) ?? child(Record(type: type, key: record.key + ":" + slot.storageKey + ":missing"))
    }

    /// A plural link. Elements that `keep` rejects are dropped, as Relay nulls a
    /// list item whose `@required` field is null.
    public func list<Element: Lens>(_ slot: Slot, keep: ((Anchor) -> Bool)? = nil) -> List<Element>? {
        switch record.read(slot) {
        case .refs(let records): return List(records: records, anchor: self, keep: keep)
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    public func requiredList<Element: Lens>(_ slot: Slot, keep: ((Anchor) -> Bool)? = nil) -> List<Element> {
        list(slot, keep: keep) ?? List(records: [], anchor: self, keep: nil)
    }
}

/// Readers by storage key, for selections on interfaces and unions: the slot is
/// resolved against the record's concrete type.
@MainActor
extension Anchor {
    public func string(key: String) -> String? { string(slot(key: key)) }
    public func requiredString(key: String) -> String { requiredString(slot(key: key)) }
    public func int(key: String) -> Int? { int(slot(key: key)) }
    public func requiredInt(key: String) -> Int { requiredInt(slot(key: key)) }
    public func double(key: String) -> Double? { double(slot(key: key)) }
    public func requiredDouble(key: String) -> Double { requiredDouble(slot(key: key)) }
    public func bool(key: String) -> Bool? { bool(slot(key: key)) }
    public func requiredBool(key: String) -> Bool { requiredBool(slot(key: key)) }
    public func strings(key: String) -> [String]? { strings(slot(key: key)) }
    public func requiredStrings(key: String) -> [String] { requiredStrings(slot(key: key)) }
    public func ints(key: String) -> [Int]? { ints(slot(key: key)) }
    public func requiredInts(key: String) -> [Int] { requiredInts(slot(key: key)) }
    public func doubles(key: String) -> [Double]? { doubles(slot(key: key)) }
    public func requiredDoubles(key: String) -> [Double] { requiredDoubles(slot(key: key)) }
    public func bools(key: String) -> [Bool]? { bools(slot(key: key)) }
    public func requiredBools(key: String) -> [Bool] { requiredBools(slot(key: key)) }
    public func linked(key: String, lookup: Lookup? = nil) -> Anchor? { linked(slot(key: key), lookup: lookup) }
    public func requiredLinked(key: String, type: TypeID, lookup: Lookup? = nil) -> Anchor { requiredLinked(slot(key: key), type: type, lookup: lookup) }
    public func list<Element: Lens>(key: String, keep: ((Anchor) -> Bool)? = nil) -> List<Element>? { list(slot(key: key), keep: keep) }
    public func requiredList<Element: Lens>(key: String, keep: ((Anchor) -> Bool)? = nil) -> List<Element> { requiredList(slot(key: key), keep: keep) }
}

/// Honest data: the readers behind `@required`, `@catch`,
/// `@throwOnFieldError` and `@defer`. Field errors live beside the field they
/// name; a required field that is null bubbles, logs or throws as the
/// directive says; a deferred fragment is present once its fields are.
@MainActor
extension Anchor {
    /// Whether a `@required` field is present. When it is not and the action is
    /// LOG, the environment is told.
    public func hasValue(_ slot: Slot, path: String, log: Bool) -> Bool {
        switch record.read(slot) {
        case .missing, .null: return requiredMissing(path: path, log: log)
        default: return true
        }
    }

    /// Reports a `@required(action: LOG)` field that is null; always false, so a
    /// guard can return it.
    public func requiredMissing(path: String, log: Bool) -> Bool {
        if log { store?.environment?.requiredFieldMissing?(record, path) }
        return false
    }

    /// Whether the field has arrived, for a deferred fragment's presence.
    public func present(_ slot: Slot) -> Bool {
        if case .missing = record.read(slot) { return false }
        return true
    }

    /// `@required(action: THROW)` on a scalar: the value, or the field's error,
    /// or `RequiredFieldError` when null.
    public func throwing<T>(_ slot: Slot, path: String, _ read: (Anchor) -> T?) throws -> T {
        if let error = record.error(slot) { throw FieldErrors([error]) }
        guard let value = read(self) else { throw RequiredFieldError(path: path) }
        return value
    }

    /// `@required(action: THROW)` on a link: the linked record, satisfied, or
    /// the field's error, or `RequiredFieldError`.
    public func throwingLinked(_ slot: Slot, lookup: Lookup? = nil, path: String, satisfied: (Anchor) -> Bool) throws -> Anchor {
        if let error = record.error(slot) { throw FieldErrors([error]) }
        guard let target = linked(slot, lookup: lookup), satisfied(target) else { throw RequiredFieldError(path: path) }
        return target
    }

    /// `@required(action: THROW)` on a plural link.
    public func throwingList<Element: Lens>(_ slot: Slot, path: String, keep: ((Anchor) -> Bool)? = nil) throws -> List<Element> {
        if let error = record.error(slot) { throw FieldErrors([error]) }
        guard let list: List<Element> = list(slot, keep: keep) else { throw RequiredFieldError(path: path) }
        return list
    }

    /// `@catch` on a scalar: the value, or the field's error.
    public func caught<T>(_ slot: Slot, _ read: (Anchor) -> T) -> Result<T, FieldErrors> {
        if let error = record.error(slot) { return .failure(FieldErrors([error])) }
        return .success(read(self))
    }

    /// `@catch` on a link: the lens, or the field's error and every error
    /// inside the linked selection.
    public func caught<T>(_ slot: Slot, within: (Anchor) -> [FieldError], _ read: (Anchor) -> T) -> Result<T, FieldErrors> {
        var errors: [FieldError] = []
        collectErrors(slot, within: within, into: &errors)
        if !errors.isEmpty { return .failure(FieldErrors(errors)) }
        return .success(read(self))
    }

    /// `@catch` on a plural link.
    public func caughtList<Element: Lens>(_ slot: Slot, within: (Anchor) -> [FieldError], keep: ((Anchor) -> Bool)? = nil) -> Result<List<Element>?, FieldErrors> {
        var errors: [FieldError] = []
        collectErrors(list: slot, within: within, into: &errors)
        if !errors.isEmpty { return .failure(FieldErrors(errors)) }
        return .success(list(slot, keep: keep))
    }

    public func caughtRequiredList<Element: Lens>(_ slot: Slot, within: (Anchor) -> [FieldError], keep: ((Anchor) -> Bool)? = nil) -> Result<List<Element>, FieldErrors> {
        caughtList(slot, within: within, keep: keep).map { (list: List<Element>?) in list ?? List(records: [], anchor: self, keep: nil) }
    }

    /// Appends the field's own error, if any.
    public func collectError(_ slot: Slot, into errors: inout [FieldError]) {
        if let error = record.error(slot) { errors.append(error) }
    }

    /// Appends the error a `@required(action: THROW)` field raises when null.
    public func collectRequired(_ slot: Slot, path: String, into errors: inout [FieldError]) {
        switch record.read(slot) {
        case .missing, .null: errors.append(.required(path: path))
        default: return
        }
    }

    /// Appends the field's own error and the errors inside the linked record.
    public func collectErrors(_ slot: Slot, within: (Anchor) -> [FieldError], into errors: inout [FieldError]) {
        collectError(slot, into: &errors)
        if case .ref(let target) = record.read(slot), !target.deleted {
            errors.append(contentsOf: within(child(target)))
        }
    }

    /// Appends the field's own error and the errors inside every linked record.
    public func collectErrors(list slot: Slot, within: (Anchor) -> [FieldError], into errors: inout [FieldError]) {
        collectError(slot, into: &errors)
        if case .refs(let targets) = record.read(slot) {
            for case let target? in targets where !target.deleted {
                errors.append(contentsOf: within(child(target)))
            }
        }
    }
}

/// Connections: the state Relay keeps on the connection record, read from the
/// store, and the fetches that extend or refresh it. The anchor's record is
/// the connection record; its parent is the fragment's owner.
@MainActor
extension Anchor {
    private func pageInfo(_ slots: ConnectionSlots) -> Record? {
        if case .ref(let record) = record.read(slots.pageInfoLink) { return record }
        return nil
    }

    private func flag(_ record: Record?, _ slot: Slot) -> Bool {
        if case .bool(let bool)? = record?.read(slot) { return bool }
        return false
    }

    /// The edges' nodes, in order, without null edges, null nodes or deleted
    /// records.
    public func nodes(_ slots: ConnectionSlots) -> [Anchor] {
        guard case .refs(let edges) = record.read(slots.edges) else { return [] }
        var nodes: [Anchor] = []
        nodes.reserveCapacity(edges.count)
        for case let edge? in edges where !edge.deleted {
            if case .ref(let node) = edge.read(slots.node), !node.deleted {
                nodes.append(Anchor(record: node, variables: variables, store: store, parent: edge))
            }
        }
        return nodes
    }

    public func hasNext(_ slots: ConnectionSlots) -> Bool { flag(pageInfo(slots), slots.hasNextPage) }
    public func hasPrevious(_ slots: ConnectionSlots) -> Bool { flag(pageInfo(slots), slots.hasPreviousPage) }
    public func isLoadingNext(_ slots: ConnectionSlots) -> Bool { flag(record, slots.isLoadingNext) }
    public func isLoadingPrevious(_ slots: ConnectionSlots) -> Bool { flag(record, slots.isLoadingPrevious) }

    /// Fetches the next `count` edges with the fragment's refetch query, after
    /// the merged end cursor; the commit appends them. A no-op while a page is
    /// loading or when there is no next page.
    public func loadNext<Op: Operation>(_ operation: Op.Type, _ slots: ConnectionSlots, _ refetch: Refetch, count: Int) async throws {
        guard let first = refetch.first, let after = refetch.after else { return }
        guard hasNext(slots), !isLoadingNext(slots), let pageInfo = pageInfo(slots), case .string(let cursor) = pageInfo.peek(slots.endCursor) else { return }
        var values = refetchVariables(refetch, owner: parent)
        values[first] = .int(count)
        values[after] = .string(cursor)
        try await environment().paginate(operation, variables: Variables(values), connection: record, loading: slots.isLoadingNext)
    }

    /// Fetches the previous `count` edges before the merged start cursor; the
    /// commit prepends them.
    public func loadPrevious<Op: Operation>(_ operation: Op.Type, _ slots: ConnectionSlots, _ refetch: Refetch, count: Int) async throws {
        guard let last = refetch.last, let before = refetch.before else { return }
        guard hasPrevious(slots), !isLoadingPrevious(slots), let pageInfo = pageInfo(slots), case .string(let cursor) = pageInfo.peek(slots.startCursor) else { return }
        var values = refetchVariables(refetch, owner: parent)
        values[last] = .int(count)
        values[before] = .string(cursor)
        try await environment().paginate(operation, variables: Variables(values), connection: record, loading: slots.isLoadingPrevious)
    }

    /// Fetches the fragment again with the lens's variables; the records
    /// update in place.
    public func refetch<Op: Operation>(_ operation: Op.Type, _ refetch: Refetch) async throws {
        _ = try await environment().fetch(operation, variables: Variables(refetchVariables(refetch, owner: record)))
    }

    /// The refetch query's variables: the lens's scope filtered to the query's
    /// definitions, plus the owner's id.
    private func refetchVariables(_ refetch: Refetch, owner: Record?) -> [String: Variable] {
        var values = variables.values.filter { refetch.variables.contains($0.key) }
        if let identifier = refetch.identifier, let id = owner?.entityID {
            values[identifier] = .string(id)
        }
        return values
    }

    private func environment() throws -> Environment {
        guard let environment = store?.environment else {
            throw TransportError(statusCode: 0, body: "the lens has no environment: it was read outside a store, so it cannot fetch")
        }
        return environment
    }
}

/// A plural link: lenses over the linked records, in order. Null elements,
/// deleted records and elements the caller rejects (a `@required` field of
/// theirs is null) are dropped.
public struct List<Element: Lens>: RandomAccessCollection, @unchecked Sendable {
    let records: ContiguousArray<Record>
    let anchor: Anchor

    @MainActor init(records: ContiguousArray<Record?>, anchor: Anchor, keep: ((Anchor) -> Bool)?) {
        var present = ContiguousArray<Record>()
        present.reserveCapacity(records.count)
        for case let record? in records where !record.deleted {
            if let keep, !keep(anchor.child(record)) { continue }
            present.append(record)
        }
        self.records = present
        self.anchor = anchor
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { records.count }
    public subscript(position: Int) -> Element { Element(anchor: anchor.child(records[position])) }
}

extension ForEach where Content: View, ID == RecordID {
    /// Iterates a list of lenses, identified by record.
    @MainActor
    public init<Element: Lens>(_ list: List<Element>, @ViewBuilder content: @escaping (Element) -> Content) where Data == List<Element> {
        self.init(list, id: \.recordID, content: content)
    }

    /// Iterates lenses, identified by record; for a connection's `nodes`.
    @MainActor
    public init<Element: Lens>(_ lenses: [Element], @ViewBuilder content: @escaping (Element) -> Content) where Data == [Element] {
        self.init(lenses, id: \.recordID, content: content)
    }
}
