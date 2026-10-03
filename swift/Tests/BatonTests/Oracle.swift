import Baton
import Foundation

/// One leaf of a response or of the store, at its response path.
struct Leaf: Equatable, Sendable, CustomStringConvertible {
    let path: String
    let value: LeafValue

    var description: String { "\(path) = \(value)" }
}

/// What a leaf holds: a scalar or a list of scalars, as both a response and
/// the store can say it.
indirect enum LeafValue: Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([LeafValue])

    /// Doubles compare by their bits, so a zero that lost its sign differs.
    static func == (lhs: LeafValue, rhs: LeafValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): a.bitPattern == b.bitPattern
        case let (.string(a), .string(b)): a == b
        case let (.list(a), .list(b)): a == b
        default: false
        }
    }

    var description: String {
        switch self {
        case .null: "null"
        case .bool(let bool): String(bool)
        case .int(let int): String(int)
        case .double(let double): String(double)
        case .string(let string): String(reflecting: string)
        case .list(let items): "[" + items.map(\.description).joined(separator: ", ") + "]"
        }
    }

    /// The value as `JSONSerialization` writes it, for editing a response.
    var json: Any {
        switch self {
        case .null: NSNull()
        case .bool(let bool): bool
        case .int(let int): int
        case .double(let double): double
        case .string(let string): string
        case .list(let items): items.map(\.json)
        }
    }
}

struct OracleError: Error, CustomStringConvertible {
    let description: String
}

/// The response as the oracle of the store: two walks over the same resolved
/// plan, one through the response's JSON as `JSONSerialization` reads it and
/// one through the records the store holds, must yield the same leaves in the
/// same order. A field the response does not carry, or the store never
/// received, yields no leaf on that side.
enum Oracle {
    /// The leaves of the raw response, read by the plan from a
    /// `JSONSerialization` tree.
    static func leaves(of response: Data, plan: ResolvedSelection) throws -> [Leaf] {
        let tree = try JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed])
        guard let object = tree as? [String: Any], let data = object["data"] as? [String: Any] else {
            throw OracleError(description: "the response has no data object")
        }
        var leaves: [Leaf] = []
        try walk(data, plan, "", &leaves)
        return leaves
    }

    /// The leaves of the store, read by the same plan from the root.
    @MainActor static func leaves(of root: Record, in store: Store, plan: ResolvedSelection) -> [Leaf] {
        var leaves: [Leaf] = []
        walk(root, store, plan, "", &leaves)
        return leaves
    }

    // MARK: The response

    private static func walk(_ object: [String: Any], _ selection: ResolvedSelection, _ path: String, _ leaves: inout [Leaf]) throws {
        // The response's own typename picks the fields, as the ingest's does.
        let type = selection.isAbstract ? (object["__typename"] as? String).map(Registry.type) ?? selection.type : selection.type
        for field in selection.variant(for: type).fields {
            guard let value = object[field.responseKey] else { continue }
            let here = path.isEmpty ? field.responseKey : path + "." + field.responseKey
            if field.responseKey == "__typename" {
                guard let name = value as? String else { throw OracleError(description: "\(here) is not a string") }
                leaves.append(Leaf(path: here, value: .string(name)))
                continue
            }
            switch field.kind {
            case .scalar(let kind, let list):
                leaves.append(Leaf(path: here, value: try scalar(value, kind, list: list, at: here)))
            case .linked(let child, let plural, _, _):
                if value is NSNull {
                    leaves.append(Leaf(path: here, value: .null))
                    continue
                }
                if !plural {
                    guard let object = value as? [String: Any] else { throw OracleError(description: "\(here) is not an object") }
                    try walk(object, child, here, &leaves)
                    continue
                }
                guard let elements = value as? [Any] else { throw OracleError(description: "\(here) is not a list") }
                for (offset, element) in elements.enumerated() {
                    let item = here + "." + String(offset)
                    if element is NSNull {
                        leaves.append(Leaf(path: item, value: .null))
                    } else if let object = element as? [String: Any] {
                        try walk(object, child, item, &leaves)
                    } else {
                        throw OracleError(description: "\(item) is not an object")
                    }
                }
            }
        }
    }

    private static func scalar(_ value: Any, _ kind: ScalarKind, list: Bool, at path: String) throws -> LeafValue {
        if value is NSNull { return .null }
        if list {
            guard let items = value as? [Any] else { throw OracleError(description: "\(path) is not a list") }
            return .list(try items.map { try scalar($0, kind, list: false, at: path) })
        }
        switch kind {
        case .string:
            guard let string = value as? String else { throw OracleError(description: "\(path) is not a string") }
            return .string(string)
        case .int:
            guard let number = value as? NSNumber else { throw OracleError(description: "\(path) is not a number") }
            return .int(number.intValue)
        case .double:
            guard let number = value as? NSNumber else { throw OracleError(description: "\(path) is not a number") }
            return .double(number.doubleValue)
        case .bool:
            guard let number = value as? NSNumber else { throw OracleError(description: "\(path) is not a boolean") }
            return .bool(number.boolValue)
        case .custom:
            if let string = value as? String { return .string(canonical(string)) }
            return .string(try canonical(json: value))
        }
    }

    // MARK: The store

    @MainActor private static func walk(_ record: Record, _ store: Store, _ selection: ResolvedSelection, _ path: String, _ leaves: inout [Leaf]) {
        for field in selection.variant(for: record.type).fields {
            let here = path.isEmpty ? field.responseKey : path + "." + field.responseKey
            if field.responseKey == "__typename" {
                leaves.append(Leaf(path: here, value: .string(record.type.name)))
                continue
            }
            var value = record.read(field.slot)
            // A page that joined its connection after a cursor keeps no link
            // on the parent; its record is where the connection's merge left
            // it, under the parent's key and the page's storage key.
            if case .missing = value, case .linked(_, _, _, .some) = field.kind,
               let page = store.existing(record.key + ":" + field.storageKey) {
                value = .ref(page)
            }
            if case .missing = value { continue }
            switch field.kind {
            case .scalar(let kind, _):
                leaves.append(Leaf(path: here, value: scalar(value, kind)))
            case .linked(let child, _, _, _):
                switch value {
                case .ref(let target) where !target.deleted:
                    walk(target, store, child, here, &leaves)
                case .refs(let targets):
                    for (offset, target) in targets.enumerated() {
                        let item = here + "." + String(offset)
                        if let target, !target.deleted {
                            walk(target, store, child, item, &leaves)
                        } else {
                            leaves.append(Leaf(path: item, value: .null))
                        }
                    }
                case .null, .ref:
                    leaves.append(Leaf(path: here, value: .null))
                default:
                    leaves.append(Leaf(path: here, value: .string("<not a link: \(value)>")))
                }
            }
        }
    }

    private static func scalar(_ value: Value, _ kind: ScalarKind) -> LeafValue {
        switch value {
        case .null, .missing: return .null
        case .bool(let bool): return kind == .custom ? .string(bool ? "true" : "false") : .bool(bool)
        case .int(let int): return kind == .custom ? .string(String(int)) : .int(int)
        case .double(let double): return kind == .custom ? .string((try? canonical(json: double)) ?? String(double)) : .double(double)
        case .string(let string): return .string(kind == .custom ? canonical(string) : string)
        case .list(let items): return .list(items.map { scalar($0, kind) })
        case .ref, .refs: return .string("<a link: \(value)>")
        }
    }

    /// A custom scalar's text in one spelling: JSON text written again with
    /// sorted keys, so `1.50` and `1.5` or two key orders agree. Text that is
    /// not JSON stays as it is.
    private static func canonical(_ text: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]), !(value is String) else {
            return text
        }
        return (try? canonical(json: value)) ?? text
    }

    private static func canonical(json value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Editing a response

    /// The response with the value at a leaf's path replaced.
    static func replacing(_ path: String, with value: LeafValue, in response: Data) throws -> Data {
        var tree = try JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed])
        tree = try replaced(tree, ["data"] + path.split(separator: ".").map(String.init), value.json)
        return try JSONSerialization.data(withJSONObject: tree, options: [.fragmentsAllowed])
    }

    private static func replaced(_ node: Any, _ path: [String], _ value: Any) throws -> Any {
        guard let head = path.first else { return value }
        let rest = Array(path.dropFirst())
        if var object = node as? [String: Any], let child = object[head] {
            object[head] = try replaced(child, rest, value)
            return object
        }
        if var array = node as? [Any], let index = Int(head), array.indices.contains(index) {
            array[index] = try replaced(array[index], rest, value)
            return array
        }
        throw OracleError(description: "no \(head) in the response")
    }
}

extension Array where Element == Leaf {
    /// The same leaves with the one at `path` holding `value`.
    func replacing(_ path: String, with value: LeafValue) -> [Leaf] {
        map { $0.path == path ? Leaf(path: path, value: value) : $0 }
    }
}
