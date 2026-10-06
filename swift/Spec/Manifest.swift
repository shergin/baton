import Foundation

/// The manifest under `spec/`: the cases every runtime is held to. A case is
/// a document, its variables, the responses in order, the records the store
/// must hold after them, and the reads a generated lens must give; written
/// in a language-neutral form, so that a runtime's reads are proved by what
/// a lens says and not by the plan it walks. `spec/README.md` is the
/// contract.
public struct Manifest: Decodable, Sendable {
    public let format: Int
    public let cases: [Case]

    public struct Case: Decodable, Sendable {
        /// The case's name, the path of its response under `spec/` without
        /// the extension.
        public let name: String
        /// The operation's name in its document.
        public let operation: String
        public let kind: Kind
        /// The operation's text with its fragments, under `spec/`.
        public let document: String
        public let variables: [String: Value]
        /// The responses in the order the server sent them: one, or an
        /// incremental response's parts.
        public let responses: [String]
        /// The store's dump after the responses, under `spec/`.
        public let records: String
        /// Whether the responses answer every field the document selects, so
        /// that the availability check passes on them.
        public let complete: Bool
        /// The leaves an optimistic response overrides, and the value they
        /// then read; several paths for aliases of one storage key.
        public let override: Override?
        /// What a generated lens reads at each path, after the responses.
        public let reads: [Read]

        private enum CodingKeys: String, CodingKey {
            case name, operation, kind, document, variables, responses, records, complete, override, reads
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            operation = try container.decode(String.self, forKey: .operation)
            kind = try container.decode(Kind.self, forKey: .kind)
            document = try container.decode(String.self, forKey: .document)
            variables = try container.decodeIfPresent([String: Value].self, forKey: .variables) ?? [:]
            responses = try container.decode([String].self, forKey: .responses)
            records = try container.decode(String.self, forKey: .records)
            complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? true
            override = try container.decodeIfPresent(Override.self, forKey: .override)
            reads = try container.decodeIfPresent([Read].self, forKey: .reads) ?? []
        }
    }

    public enum Kind: String, Decodable, Sendable {
        case query, mutation, subscription
    }

    public struct Override: Decodable, Sendable {
        public let paths: [String]
        public let value: Value
    }

    public struct Read: Decodable, Sendable {
        /// Response keys and list indices from the root, joined by dots.
        public let path: String
        public let value: Value
        /// Why the value is not the response's leaf, when it is not: the
        /// runtime's rule that reads it so.
        public let note: String?
    }

    /// A JSON value as the manifest spells it: what a variable is given and
    /// what a read yields.
    public indirect enum Value: Decodable, Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case list([Value])
        case object([String: Value])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let list = try? container.decode([Value].self) {
                self = .list(list)
            } else {
                self = .object(try container.decode([String: Value].self))
            }
        }
    }
}

extension Spec {
    /// The manifest, `spec/manifest.json`, read in place.
    public static let manifest: Manifest = {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data("manifest.json"))
        } catch {
            fatalError("Spec: manifest.json does not read: \(error)")
        }
    }()
}
