import Foundation

/// What a record's slot holds. `missing` means the store never received the
/// field; `null` means the server said so.
public enum Value {
    case missing
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case ref(Record)
    case refs(ContiguousArray<Record?>)
    case list(ContiguousArray<Value>)
}

/// A record is isolated to the main actor, so a value that holds one can be
/// handed to another thread, which may read the record's identity and no more.
extension Value: Sendable {}

extension Value: Equatable {
    /// Records compare by identity: the store holds one object per key.
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.missing, .missing), (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.ref(a), .ref(b)): a === b
        case let (.refs(a), .refs(b)): a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
        case let (.list(a), .list(b)): a == b
        default: false
        }
    }
}

/// An operation variable: JSON-shaped, hashable, sendable.
public enum Variable: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([Variable])
    case object([String: Variable])

    public init(_ value: Int?) { self = value.map(Variable.int) ?? .null }
    public init(_ value: Double?) { self = value.map(Variable.double) ?? .null }
    public init(_ value: Bool?) { self = value.map(Variable.bool) ?? .null }
    public init(_ value: String?) { self = value.map(Variable.string) ?? .null }
    public init(_ value: [String]?) { self = value.map { .list($0.map(Variable.string)) } ?? .null }
    public init(_ value: [Int]?) { self = value.map { .list($0.map(Variable.int)) } ?? .null }
    public init(_ value: [Double]?) { self = value.map { .list($0.map(Variable.double)) } ?? .null }
    public init(_ value: [Bool]?) { self = value.map { .list($0.map(Variable.bool)) } ?? .null }
    /// Lists whose elements the schema types nullable: a nil element is a
    /// null in the request.
    public init(_ value: [String?]?) { self = value.map { .list($0.map(Variable.init)) } ?? .null }
    public init(_ value: [Int?]?) { self = value.map { .list($0.map(Variable.init)) } ?? .null }
    public init(_ value: [Double?]?) { self = value.map { .list($0.map(Variable.init)) } ?? .null }
    public init(_ value: [Bool?]?) { self = value.map { .list($0.map(Variable.init)) } ?? .null }
    public init(_ value: Variable?) { self = value ?? .null }
    public init(_ value: [Variable]?) { self = value.map(Variable.list) ?? .null }
    /// An input object is sent as the object its struct renders.
    public init<T: InputObject>(_ value: T?) { self = value?.variable ?? .null }
    public init<T: InputObject>(_ value: [T]?) { self = value.map { .list($0.map(\.variable)) } ?? .null }
    public init<T: InputObject>(_ value: [T?]?) { self = value.map { .list($0.map { Variable($0) }) } ?? .null }
    /// A mapped scalar is sent as its text.
    public init<T: MappedScalar>(_ value: T?) { self = value.map { .string($0.scalarText) } ?? .null }
    public init<T: MappedScalar>(_ value: [T]?) { self = value.map { .list($0.map { .string($0.scalarText) }) } ?? .null }
    public init<T: MappedScalar>(_ value: [T?]?) { self = value.map { .list($0.map { Variable($0) }) } ?? .null }

    /// JSON text, with object keys sorted so equal values render equally.
    public var json: String {
        switch self {
        case .null: "null"
        case .bool(let bool): bool ? "true" : "false"
        case .int(let int): String(int)
        case .double(let double): String(double)
        case .string(let string): Variable.quote(string)
        case .list(let items): "[" + items.map(\.json).joined(separator: ",") + "]"
        case .object(let fields):
            "{" + fields.keys.sorted().map { Variable.quote($0) + ":" + fields[$0]!.json }.joined(separator: ",") + "}"
        }
    }

    /// The value as a record key segment: strings unquoted, everything else as JSON.
    package var keyText: String {
        if case .string(let string) = self { return string }
        return json
    }

    static func quote(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }
}

/// A Swift struct generated for a schema input object: a property per field,
/// typed as the schema types it, and the object the request carries. A field
/// left nil is absent from the request, as GraphQL distinguishes absent from
/// null. Hashable, as the operation value whose variable it is compares and
/// hashes its variables.
public protocol InputObject: Hashable, Sendable {
    var variable: Variable { get }
}

/// Boxes a field of an input object whose type contains the input itself,
/// directly or through other inputs, which a value type cannot hold:
/// `input Filter { not: Filter }`. Generated code stores such a field in one
/// of these behind a property of the field's own type.
public struct Indirect<Value: Hashable & Sendable>: Hashable, Sendable {
    private final class Box: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private var box: Box

    public init(_ value: Value) { box = Box(value) }

    public var value: Value {
        get { box.value }
        set { box = Box(newValue) }
    }

    public static func == (lhs: Indirect, rhs: Indirect) -> Bool { lhs.box.value == rhs.box.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(box.value) }
}

/// An operation's variables by name.
public struct Variables: Hashable, Sendable {
    public let values: [String: Variable]

    public init(_ values: [String: Variable]) { self.values = values }

    public static let none = Variables([:])

    public subscript(name: String) -> Variable? { values[name] }

    /// The JSON rendering used inside storage keys, as Relay does: `characters(page:1)`.
    package func render(_ name: String) -> String { (values[name] ?? .null).json }

    /// The rendering used inside record keys for lookups: `Character:1`.
    package func keyText(_ name: String) -> String { (values[name] ?? .null).keyText }

    /// The `variables` object of a request body.
    public var json: String { Variable.object(values).json }
}
