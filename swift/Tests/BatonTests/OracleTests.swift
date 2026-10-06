@_spi(Generated) import Baton
import BatonSpec
import BatonTesting
import Foundation
import Testing

/// A case of `spec/manifest.json`: the responses, the operation that reads
/// them, where they hang, and what the store and the lens must give after.
struct OracleCase: Sendable, CustomTestStringConvertible {
    let entry: Manifest.Case

    var testDescription: String { entry.name }

    static let all = Spec.manifest.cases.map(OracleCase.init(entry:))

    var rootKey: String {
        switch entry.kind {
        case .query: Store.rootKey
        case .mutation: Store.mutationRootKey
        case .subscription: Store.subscriptionRootKey
        }
    }

    @MainActor func root(in store: Store) -> Record {
        switch entry.kind {
        case .query: store.root
        case .mutation: store.mutationRoot
        case .subscription: store.subscriptionRoot
        }
    }

    /// Whether the image is read back: it keeps what hangs off the query
    /// root only.
    var persisted: Bool { entry.kind == .query }

    /// The dump's name as `StoreDump` takes it, without the extension.
    var dumpName: String {
        let suffix = ".store.json"
        return entry.records.hasSuffix(suffix) ? String(entry.records.dropLast(suffix.count)) : entry.records
    }

    var parts: [Data] { entry.responses.map(Spec.data) }

    /// The response the parts add up to: the one response, or the first part
    /// with every later part merged in at its path.
    func response() throws -> Data {
        let parts = parts
        guard let first = parts.first else { throw OracleError(description: "\(entry.name) lists no response") }
        return parts.count == 1 ? first : try Oracle.merging(Array(parts.dropFirst()), into: first)
    }

    /// Commits the responses into a store: one response directly, the parts
    /// of an incremental response through a fetch, as an app receives them.
    @MainActor func commit(_ operation: OracleOperation, into store: Store) async throws {
        let parts = parts
        if parts.count == 1 {
            let plan = operation.plan.resolve(operation.variables, in: store.keys)
            store.commit(try Ingest.normalize(parts[0], plan: plan, rootKey: rootKey))
            return
        }
        guard let fetch = operation.fetch else {
            throw OracleError(description: "\(entry.name): only a query takes its responses in parts")
        }
        try await fetch(Environment(transport: Parts(parts), store: store))
    }
}

@MainActor
@Suite("The response is the oracle", .timeLimit(.minutes(1)))
struct OracleTests {
    @Test("the store reads back every leaf of the response, after the commit as its dump in spec/ says, from the image in a second store, and under a layer that overrides one leaf", arguments: OracleCase.all)
    func theStoreAgreesWithTheResponse(_ oracle: OracleCase) async throws {
        let operation = try OracleOperation.bind(oracle.entry)
        let response = try oracle.response()
        let image = TemporaryImage()
        let persistence = Persistence(url: image.url)
        let store = Store(persistence: oracle.persisted ? persistence : nil)
        let plan = operation.plan.resolve(operation.variables, in: store.keys)
        store.reportMissing = nil
        try await oracle.commit(operation, into: store)
        // The response is walked after the commit: a type the build did not
        // list takes its variant from the memberships the response states,
        // which the store learns at the commit, and the variant is settled
        // once per type.
        let expected = try Oracle.leaves(of: response, plan: plan)
        #expect(!expected.isEmpty)
        expectSame(Oracle.leaves(of: oracle.root(in: store), plan: plan), expected, "after the commit")
        StoreDump.expectMatches(store, oracle.dumpName)

        if oracle.persisted {
            await persistence.close()
            let second = Store(persistence: Persistence(url: image.url))
            second.reportMissing = nil
            let environment = Environment(transport: SilentTransport(), store: second)
            let secondPlan = operation.plan.resolve(operation.variables, in: second.keys)
            let answered = environment.store.check(secondPlan)
            if oracle.entry.complete { #expect(answered == .image, "the image answers the plan") }
            // The check passes over deferred fields, so the image answers an
            // incremental response's initial part, and its operation fetches.
            let initial = oracle.parts.count == 1 ? expected : try Oracle.leaves(of: oracle.parts[0], plan: secondPlan)
            expectSame(Oracle.leaves(of: second.root, plan: secondPlan), initial, "from the image")
        }

        guard let override = oracle.entry.override else { return }
        let value = try LeafValue(override.value)
        var edited = response
        var overridden = expected
        for path in override.paths {
            edited = try Oracle.replacing(path, with: value, in: edited)
            overridden = overridden.replacing(path, with: value)
        }
        let layer = store.applyOptimistic(try Ingest.normalize(edited, plan: plan, rootKey: oracle.rootKey))
        expectSame(Oracle.leaves(of: oracle.root(in: store), plan: plan), overridden, "under the layer")
        store.revertOptimistic(layer)
        expectSame(Oracle.leaves(of: oracle.root(in: store), plan: plan), expected, "after the layer is reverted")
    }

    @Test("the generated lens reads every value the manifest lists for the case, through its own accessors and not the plan", arguments: OracleCase.all)
    func theLensAgreesWithTheManifest(_ oracle: OracleCase) async throws {
        let operation = try OracleOperation.bind(oracle.entry)
        let store = Store()
        store.reportMissing = nil
        try await oracle.commit(operation, into: store)
        let anchor = Anchor(record: oracle.root(in: store), variables: operation.variables, store: store)
        for row in oracle.entry.reads {
            guard let read = operation.readers[row.path] else {
                Issue.record("\(oracle.entry.name): no reader of \(operation.name) for \(row.path)")
                continue
            }
            let value = read(anchor)
            let expected = operation.spellings[row.path]?(row.value) ?? row.value
            if !value.isSameJSON(as: expected) {
                Issue.record("\(oracle.entry.name): the lens reads \(row.path) as \(value) where the manifest has \(row.value)")
            }
        }
    }

    @Test("every operation the manifest names has its document under spec/documents, equal to the text the compiler generated")
    func theDocumentsAgreeWithTheGeneratedText() throws {
        var documents: [String: String] = [:]
        for entry in Spec.manifest.cases {
            do {
                documents[entry.document] = try OracleOperation.bind(entry).text + "\n"
            } catch {
                Issue.record("\(entry.name): \(error)")
            }
        }
        let bless = ProcessInfo.processInfo.environment["BATON_BLESS"] != nil
        for (path, text) in documents.sorted(by: { $0.key < $1.key }) {
            let url = Spec.directory.appendingPathComponent(path)
            if bless {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                continue
            }
            guard let written = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("\(path) is missing; run the tests with BATON_BLESS=1 to write it")
                continue
            }
            #expect(written == text, "\(path) differs from the text the compiler generated")
        }
    }

    /// Compares two leaf lists and names the first leaf where they part.
    func expectSame(_ actual: [Leaf], _ expected: [Leaf], _ stage: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard actual != expected else { return }
        let index = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actual.count, expected.count)
        let store = index < actual.count ? actual[index].description : "<end>"
        let response = index < expected.count ? expected[index].description : "<end>"
        Issue.record("\(stage): the store reads \(store) where the response has \(response) (leaf \(index) of \(expected.count))", sourceLocation: sourceLocation)
    }
}

extension Manifest.Value {
    /// Whether two values are the same JSON: a number is one number however
    /// it is spelled, so a `Float` the lens reads as 2.0 is the manifest's 2.
    func isSameJSON(as other: Manifest.Value) -> Bool {
        switch (self, other) {
        case (.int(let int), .double(let double)), (.double(let double), .int(let int)):
            return Double(int) == double
        case (.list(let items), .list(let others)):
            return items.count == others.count && zip(items, others).allSatisfy { $0.isSameJSON(as: $1) }
        default:
            return self == other
        }
    }
}

extension LeafValue {
    /// A manifest value as a leaf; an object is no leaf.
    init(_ value: Manifest.Value) throws {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .string(let string): self = .string(string)
        case .list(let items): self = .list(try items.map(LeafValue.init))
        case .object: throw OracleError(description: "an object is not a leaf")
        }
    }
}

/// Streams the parts of an incremental response in order.
struct Parts: Transport {
    let parts: [Data]

    init(_ parts: [Data]) { self.parts = parts }

    func execute(_ request: Request) async throws -> Data { parts[0] }

    func stream(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            continuation.finish()
        }
    }
}

extension Oracle {
    /// The first part of an incremental response with every later part's
    /// items placed at their paths: the response the parts add up to.
    static func merging(_ later: [Data], into first: Data) throws -> Data {
        guard var tree = try JSONSerialization.jsonObject(with: first) as? [String: Any] else {
            throw OracleError(description: "the first part is not an object")
        }
        var pending: [String: [Any]] = [:]
        for announced in (tree["pending"] as? [[String: Any]]) ?? [] {
            if let id = announced["id"] as? String, let path = announced["path"] as? [Any] { pending[id] = path }
        }
        for part in later {
            guard let object = try JSONSerialization.jsonObject(with: part) as? [String: Any] else { continue }
            for announced in (object["pending"] as? [[String: Any]]) ?? [] {
                if let id = announced["id"] as? String, let path = announced["path"] as? [Any] { pending[id] = path }
            }
            for item in (object["incremental"] as? [[String: Any]]) ?? [] {
                guard let data = item["data"] as? [String: Any] else { continue }
                let path = (item["path"] as? [Any]) ?? (item["id"] as? String).flatMap { pending[$0] } ?? []
                tree["data"] = try merged(tree["data"] as Any, path.map { "\($0)" }, data)
            }
        }
        tree.removeValue(forKey: "pending")
        tree.removeValue(forKey: "hasNext")
        return try JSONSerialization.data(withJSONObject: tree)
    }

    private static func merged(_ node: Any, _ path: [String], _ data: [String: Any]) throws -> Any {
        guard let head = path.first else {
            guard var object = node as? [String: Any] else { throw OracleError(description: "a part lands on something that is not an object") }
            for (key, value) in data { object[key] = value }
            return object
        }
        let rest = Array(path.dropFirst())
        if var object = node as? [String: Any], let child = object[head] {
            object[head] = try merged(child, rest, data)
            return object
        }
        if var array = node as? [Any], let index = Int(head), array.indices.contains(index) {
            array[index] = try merged(array[index], rest, data)
            return array
        }
        throw OracleError(description: "a part's path names \(head), which the response does not have")
    }
}
