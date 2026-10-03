import SwiftUI

/// Where a lens reads from: one record, and the variables that bind any
/// argument-carrying storage key along its path.
public struct Anchor: @unchecked Sendable {
    public let record: Record
    public let variables: Variables
    let store: Store?

    public init(record: Record, variables: Variables, store: Store? = nil) {
        self.record = record
        self.variables = variables
        self.store = store
    }

    func child(_ record: Record) -> Anchor { Anchor(record: record, variables: variables, store: store) }
}

/// A typed, read-only view over one record: a fragment's or an operation's
/// data. The compiler generates one struct per selection; this protocol is
/// what they share.
public protocol Lens: Sendable {
    var anchor: Anchor { get }
    init(anchor: Anchor)
    static var typeName: String { get }
}

extension Lens {
    /// The record's identity, for list diffing.
    @MainActor public var recordID: RecordID { RecordID(anchor.record) }
}

@MainActor
extension Anchor {
    private func missing(_ slot: Slot) {
        anchor.store?.reportMissing?(record, slot)
    }

    private var anchor: Anchor { self }

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
        case .double(let double): return Int(double)
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
    /// never fetched but the entity is cached.
    public func linked(_ slot: Slot, lookup: Lookup? = nil) -> Anchor? {
        switch record.read(slot) {
        case .ref(let target): return child(target)
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

    public func list<Element: Lens>(_ slot: Slot) -> List<Element>? {
        switch record.read(slot) {
        case .refs(let records): return List(records: records, anchor: self)
        case .missing: missing(slot); return nil
        default: return nil
        }
    }

    public func requiredList<Element: Lens>(_ slot: Slot) -> List<Element> {
        list(slot) ?? List(records: [], anchor: self)
    }
}

/// A plural link: lenses over the linked records, in order. Null elements are
/// dropped; `@required` semantics for list items arrive with 0.5.
public struct List<Element: Lens>: RandomAccessCollection, @unchecked Sendable {
    let records: ContiguousArray<Record>
    let anchor: Anchor

    @MainActor init(records: ContiguousArray<Record?>, anchor: Anchor) {
        var present = ContiguousArray<Record>()
        present.reserveCapacity(records.count)
        for case let record? in records { present.append(record) }
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
}
