import Foundation

/// The manifest under `spec/`: the cases every runtime is held to. A case is
/// a document, its variables, the responses in order, the records the store
/// must hold after them, and the reads a generated lens must give; written
/// in a language-neutral form, so that a runtime's reads are proved by what
/// a lens says and not by the plan it walks. A script is steps over time and
/// what each must leave. `spec/README.md` is the contract.
public struct Manifest: Decodable, Sendable {
    public let format: Int
    public let cases: [Case]
    /// The scripts' files under `spec/`, in the order they run.
    public let scripts: [String]
    /// The authors' documents the cases and scripts read, and the
    /// configuration they compile with.
    public let sources: Sources

    private enum CodingKeys: String, CodingKey {
        case format, cases, scripts, sources
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        cases = try container.decode([Case].self, forKey: .cases)
        scripts = try container.decodeIfPresent([String].self, forKey: .scripts) ?? []
        sources = try container.decode(Sources.self, forKey: .sources)
    }

    /// Where the authors' documents are: a directory of `.graphql` files, one
    /// for each document, and the `baton.json` they compile with, both paths
    /// under `spec/`.
    public struct Sources: Decodable, Sendable {
        public let config: String
        public let directory: String
    }

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
        /// What the read yields; null when the row says it throws.
        public let value: Value
        /// What the read throws instead of yielding: `requiredField` or
        /// `fieldErrors`. At the empty path, what the operation itself
        /// fails with.
        public let `throws`: String?
        /// A `@catch` read's result: `{"ok": true, "value": …}`, the value
        /// left out for a lens, or `{"ok": false, "errors": [path, …]}`.
        public let result: Value?
        /// Why the value is not the response's leaf, when it is not: the
        /// runtime's rule that reads it so.
        public let note: String?

        private enum CodingKeys: String, CodingKey {
            case path, value, `throws`, result, note
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            `throws` = try container.decodeIfPresent(String.self, forKey: .throws)
            result = try container.decodeIfPresent(Value.self, forKey: .result)
            // A row that throws or reads a result needs no value.
            if `throws` == nil && result == nil {
                value = try container.decode(Value.self, forKey: .value)
            } else {
                value = try container.decodeIfPresent(Value.self, forKey: .value) ?? .null
            }
            note = try container.decodeIfPresent(String.self, forKey: .note)
        }
    }

    /// A JSON value as the manifest spells it: what a variable is given and
    /// what a read yields. Described as the JSON it is.
    public indirect enum Value: Decodable, Sendable, Equatable, CustomStringConvertible {
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

        public var description: String {
            switch self {
            case .null: "null"
            case .bool(let bool): "\(bool)"
            case .int(let int): "\(int)"
            case .double(let double): "\(double)"
            case .string(let string): "\"" + string + "\""
            case .list(let items): "[" + items.map(\.description).joined(separator: ", ") + "]"
            case .object(let members): "{" + members.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ", ") + "}"
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

// MARK: Scripts

extension Manifest {
    /// A script under `spec/scripts/`: steps run in order in one environment
    /// over one store, and after any step the facts the runtime must then
    /// show.
    public struct Script: Decodable, Sendable {
        /// The script's name, the name of its file without the extension.
        public let name: String
        /// Whether the store keeps an image, on a file of the harness's
        /// choosing, so that `relaunch` opens a second store over it.
        public let image: Bool
        /// How many released roots the store keeps alive; ten by default.
        public let buffer: Int
        /// The store's default expiration in seconds, for an operation that
        /// states none; none by default.
        public let expiration: Double?
        public let steps: [Step]

        private enum CodingKeys: String, CodingKey {
            case name, image, buffer, expiration, steps
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            image = try container.decodeIfPresent(Bool.self, forKey: .image) ?? false
            buffer = try container.decodeIfPresent(Int.self, forKey: .buffer) ?? 10
            expiration = try container.decodeIfPresent(Double.self, forKey: .expiration)
            steps = try container.decode([Step].self, forKey: .steps)
        }

        /// Reads a script by its path under `spec/`.
        public static func load(_ path: String) throws -> Script {
            try JSONDecoder().decode(Script.self, from: Spec.data(path))
        }
    }

    /// An operation a step names: its name in its document and the variables
    /// it runs with.
    public struct Operation: Sendable {
        public let name: String
        public let variables: [String: Value]

        public init(name: String, variables: [String: Value]) {
            self.name = name
            self.variables = variables
        }
    }

    /// How the transport answers a request: with a response under `spec/`,
    /// or with a failure of a kind.
    public enum Reply: Sendable {
        case response(String)
        case failure(FailureKind)
    }

    /// The failures a step may script: the transport throws, the server
    /// answers errors and no data, or a response the plan cannot read.
    public enum FailureKind: String, Decodable, Sendable {
        case transport, request, malformed
    }

    /// What a subscription's stream receives: an event, a failure, or the
    /// server's completion.
    public enum Delivery: Sendable {
        case response(String)
        case failure(FailureKind)
        case complete
    }

    /// A fetch policy, by its name.
    public enum Policy: String, Decodable, Sendable {
        case storeOrNetwork, storeAndNetwork, networkOnly, storeOnly
    }

    /// The availability check's answer.
    public enum Answer: String, Decodable, Sendable {
        case memory, image, miss
    }

    /// One step of a script and the expectations beside it, each compared
    /// after the step.
    public struct Step: Decodable, Sendable {
        public let action: Action
        /// The store's dump after the step, under `spec/`.
        public let records: String?
        public let reads: [ScriptRead]
        /// The fields the step's batches notified, and nothing else; `[]`
        /// says the step notified nothing.
        public let notified: [Notification]?
        /// Handles' phases, fetches and streams: one object, or a list of
        /// them for several handles.
        public let phases: [PhaseExpectation]
        public let fetches: [FetchExpectation]
        public let streams: [StreamExpectation]
        /// The check's answer, beside a `check` step.
        public let answer: Answer?
        /// The keys the store holds, sorted.
        public let recordsHeld: [String]?
        /// The log's events during the step, in order.
        public let events: [Event]?
        /// The requests the transport received during the step, in order.
        public let sent: [SentRequest]?
        /// The kind of what the step threw, when it is expected to throw.
        public let error: String?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            // `answer` names a step when its value is an object of arguments,
            // and the check's expected answer when it is a word.
            let answerIsExpectation = (try? container.decode(Answer.self, forKey: AnyKey("answer"))) != nil
            let kinds = container.allKeys.map(\.stringValue).filter { Action.kinds.contains($0) && !($0 == "answer" && answerIsExpectation) }
            guard kinds.count == 1, let kind = kinds.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a step names one kind of step, not \(kinds)"))
            }
            action = try Action(kind, try container.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(kind)))
            records = try container.decodeIfPresent(String.self, forKey: AnyKey("records"))
            reads = try container.decodeIfPresent([ScriptRead].self, forKey: AnyKey("reads")) ?? []
            notified = try container.decodeIfPresent([Notification].self, forKey: AnyKey("notified"))
            phases = try Self.one(or: PhaseExpectation.self, "phase", in: container)
            fetches = try Self.one(or: FetchExpectation.self, "fetch", in: container)
            streams = try Self.one(or: StreamExpectation.self, "stream", in: container)
            answer = answerIsExpectation ? try container.decode(Answer.self, forKey: AnyKey("answer")) : nil
            recordsHeld = try container.decodeIfPresent([String].self, forKey: AnyKey("records_held"))
            events = try container.decodeIfPresent([Event].self, forKey: AnyKey("events"))
            sent = try container.decodeIfPresent([SentRequest].self, forKey: AnyKey("sent"))
            error = try container.decodeIfPresent(String.self, forKey: AnyKey("error"))
        }

        /// An expectation given as one object or as a list of them.
        private static func one<T: Decodable>(or type: T.Type, _ key: String, in container: KeyedDecodingContainer<AnyKey>) throws -> [T] {
            guard container.contains(AnyKey(key)) else { return [] }
            if let list = try? container.decode([T].self, forKey: AnyKey(key)) { return list }
            return [try container.decode(T.self, forKey: AnyKey(key))]
        }
    }

    /// What a step does, with its arguments.
    public enum Action: Sendable {
        case commit(Operation, responses: [String])
        case payload(Operation, response: String)
        case optimistic(Operation, response: String, name: String)
        case resolve(layer: String, response: String)
        case revert(layer: String)
        case attach(Operation, policy: Policy, name: String, reply: Reply?)
        case answer(handle: String, reply: Reply)
        case refetch(handle: String, reply: Reply)
        case retry(handle: String, reply: Reply?)
        case release(handle: String)
        case collect
        case advance(seconds: Double)
        case invalidate
        case revalidate
        case check(Operation)
        case relaunch
        case event(handle: String, delivery: Delivery)
        case active(Bool)
        case end

        static let kinds: Set<String> = [
            "commit", "payload", "optimistic", "resolve", "revert", "attach", "answer", "refetch", "retry", "release",
            "collect", "advance", "invalidate", "revalidate", "check", "relaunch", "event", "active", "end",
        ]

        /// The step's kind, as the script names it.
        public var kind: String {
            switch self {
            case .commit: "commit"
            case .payload: "payload"
            case .optimistic: "optimistic"
            case .resolve: "resolve"
            case .revert: "revert"
            case .attach: "attach"
            case .answer: "answer"
            case .refetch: "refetch"
            case .retry: "retry"
            case .release: "release"
            case .collect: "collect"
            case .advance: "advance"
            case .invalidate: "invalidate"
            case .revalidate: "revalidate"
            case .check: "check"
            case .relaunch: "relaunch"
            case .event: "event"
            case .active: "active"
            case .end: "end"
            }
        }

        init(_ kind: String, _ arguments: KeyedDecodingContainer<AnyKey>) throws {
            func string(_ key: String) throws -> String { try arguments.decode(String.self, forKey: AnyKey(key)) }
            func operation() throws -> Operation {
                Operation(name: try string("operation"), variables: try arguments.decodeIfPresent([String: Value].self, forKey: AnyKey("variables")) ?? [:])
            }
            func reply() throws -> Reply? {
                if let response = try arguments.decodeIfPresent(String.self, forKey: AnyKey("response")) { return .response(response) }
                if let failure = try arguments.decodeIfPresent(FailureKind.self, forKey: AnyKey("failure")) { return .failure(failure) }
                return nil
            }
            func requiredReply() throws -> Reply {
                guard let reply = try reply() else {
                    throw DecodingError.dataCorrupted(.init(codingPath: arguments.codingPath, debugDescription: "a \(kind) step gives a response or a failure"))
                }
                return reply
            }
            switch kind {
            case "commit":
                let responses = try arguments.decodeIfPresent([String].self, forKey: AnyKey("responses")) ?? [try string("response")]
                self = .commit(try operation(), responses: responses)
            case "payload": self = .payload(try operation(), response: try string("response"))
            case "optimistic": self = .optimistic(try operation(), response: try string("response"), name: try string("as"))
            case "resolve": self = .resolve(layer: try string("layer"), response: try string("response"))
            case "revert": self = .revert(layer: try string("layer"))
            case "attach":
                let policy = try arguments.decodeIfPresent(Policy.self, forKey: AnyKey("policy")) ?? .storeOrNetwork
                self = .attach(try operation(), policy: policy, name: try string("as"), reply: try reply())
            case "answer": self = .answer(handle: try string("handle"), reply: try requiredReply())
            case "refetch": self = .refetch(handle: try string("handle"), reply: try requiredReply())
            case "retry": self = .retry(handle: try string("handle"), reply: try reply())
            case "release": self = .release(handle: try string("handle"))
            case "collect": self = .collect
            case "advance": self = .advance(seconds: try arguments.decode(Double.self, forKey: AnyKey("seconds")))
            case "invalidate": self = .invalidate
            case "revalidate": self = .revalidate
            case "check": self = .check(try operation())
            case "relaunch": self = .relaunch
            case "event":
                let handle = try string("handle")
                if try arguments.decodeIfPresent(Bool.self, forKey: AnyKey("complete")) == true {
                    self = .event(handle: handle, delivery: .complete)
                    return
                }
                switch try requiredReply() {
                case .response(let response): self = .event(handle: handle, delivery: .response(response))
                case .failure(let failure): self = .event(handle: handle, delivery: .failure(failure))
                }
            case "active": self = .active(try arguments.decode(Bool.self, forKey: AnyKey("value")))
            case "end": self = .end
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: arguments.codingPath, debugDescription: "no step is named \(kind)"))
            }
        }
    }

    /// A read a step expects: a case's row, read through a handle's data or
    /// through a lens made by hand over the root of an operation's kind.
    public struct ScriptRead: Decodable, Sendable {
        public let handle: String?
        public let operation: String?
        public let variables: [String: Value]
        public let path: String
        /// What the read yields; null when the row says it throws.
        public let value: Value
        /// What the read throws instead, as a case's row says it.
        public let `throws`: String?
        /// A `@catch` read's result, as a case's row says it.
        public let result: Value?
        public let note: String?

        private enum CodingKeys: String, CodingKey {
            case handle, operation, variables, path, value, `throws`, result, note
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            handle = try container.decodeIfPresent(String.self, forKey: .handle)
            operation = try container.decodeIfPresent(String.self, forKey: .operation)
            variables = try container.decodeIfPresent([String: Value].self, forKey: .variables) ?? [:]
            path = try container.decode(String.self, forKey: .path)
            `throws` = try container.decodeIfPresent(String.self, forKey: .throws)
            result = try container.decodeIfPresent(Value.self, forKey: .result)
            if `throws` == nil && result == nil {
                value = try container.decode(Value.self, forKey: .value)
            } else {
                value = try container.decodeIfPresent(Value.self, forKey: .value) ?? .null
            }
            note = try container.decodeIfPresent(String.self, forKey: .note)
        }
    }

    /// A field a batch notified: the record's key and the field's storage
    /// key.
    public struct Notification: Decodable, Sendable, Hashable, CustomStringConvertible {
        public let record: String
        public let field: String

        public init(record: String, field: String) {
            self.record = record
            self.field = field
        }

        public var description: String { record + "." + field }
    }

    /// A state as a script spells it: a word (`ready`), or a word and its
    /// kind (`{"failed": "transport"}`, `{"ended": null}`).
    public enum State: Decodable, Sendable, Equatable, CustomStringConvertible {
        case plain(String)
        case tagged(String, String?)

        public init(from decoder: any Decoder) throws {
            if let word = try? decoder.singleValueContainer().decode(String.self) {
                self = .plain(word)
                return
            }
            let container = try decoder.container(keyedBy: AnyKey.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a state is a word or an object of one key"))
            }
            self = .tagged(key.stringValue, try container.decodeIfPresent(String.self, forKey: key))
        }

        public var description: String {
            switch self {
            case .plain(let word): word
            case .tagged(let word, let kind): "\(word)(\(kind ?? "null"))"
            }
        }
    }

    /// A handle's phase, with whether it is refreshing and stale when they
    /// matter.
    public struct PhaseExpectation: Decodable, Sendable {
        public let handle: String
        public let phase: State
        public let isRefreshing: Bool?
        public let isStale: Bool?
    }

    /// A handle's fetch.
    public struct FetchExpectation: Decodable, Sendable {
        public let handle: String
        public let fetch: State
    }

    /// A subscription handle's stream, with its count of events and of
    /// resumptions when they matter.
    public struct StreamExpectation: Decodable, Sendable {
        public let handle: String
        public let stream: State
        public let events: Int?
        public let resumptions: Int?
    }

    /// A request the transport received: its operation's name and the body
    /// the standard encoding writes for it, byte for byte.
    public struct SentRequest: Decodable, Sendable {
        public let operation: String
        public let body: String
    }

    /// A log event: its name, and the value-free fields it carries that the
    /// script compares. A bare name compares the name alone.
    public struct Event: Decodable, Sendable, CustomStringConvertible {
        public let name: String
        public let fields: [String: Value]

        public init(name: String, fields: [String: Value]) {
            self.name = name
            self.fields = fields
        }

        public init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
                fields = [:]
                return
            }
            let container = try decoder.container(keyedBy: AnyKey.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an event is a name or an object of one key"))
            }
            name = key.stringValue
            fields = try container.decode([String: Value].self, forKey: key)
        }

        public var description: String {
            fields.isEmpty ? name : name + "(" + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + ")"
        }
    }

    /// A coding key of any name, for objects keyed by what they hold.
    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
