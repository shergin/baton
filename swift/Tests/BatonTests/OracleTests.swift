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

    /// The tests' `baton.json` `transient` block: the types whose records
    /// and the root fields, as `Query.secrets`, the image never keeps.
    static let transient: (types: Set<String>, fields: Set<String>) = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("baton.json")
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let block = config["transient"] as? [String: Any]
        else { return ([], []) }
        return (Set(block["types"] as? [String] ?? []), Set(block["fields"] as? [String] ?? []))
    }()

    /// Whether the dump holds what the configuration keeps off the image: a
    /// record of a transient type, or a cell of a transient root field. The
    /// image then answers the operation with a miss, and it fetches.
    var keptOffTheImage: Bool {
        guard let dump = try? JSONSerialization.jsonObject(with: Spec.data(entry.records)) as? [String: Any] else { return false }
        for (key, record) in dump {
            guard let record = record as? [String: Any], let type = record["__typename"] as? String else { continue }
            if Self.transient.types.contains(type) { return true }
            guard key == Store.rootKey else { continue }
            for field in record.keys where Self.transient.fields.contains(type + "." + field.prefix { $0 != "(" }) {
                return true
            }
        }
        return false
    }

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

    /// The response without its deferred parts: the first part with every
    /// streamed item placed, what the image answers a check with.
    func streamedResponse() throws -> Data {
        let parts = parts
        guard let first = parts.first else { throw OracleError(description: "\(entry.name) lists no response") }
        return parts.count == 1 ? first : try Oracle.merging(Array(parts.dropFirst()), into: first, deferred: false)
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
        store.log = nil
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
            second.log = nil
            let environment = Environment(transport: SilentTransport(), store: second)
            let secondPlan = operation.plan.resolve(operation.variables, in: second.keys)
            let answered = environment.store.check(secondPlan)
            // What the configuration keeps off the image is fetched again;
            // `TransientTests` proves what the image holds of such a case.
            if oracle.keptOffTheImage {
                #expect(answered == .miss, "the image keeps the transient records off, so the plan misses")
            } else {
                if oracle.entry.complete { #expect(answered == .image, "the image answers the plan") }
                // The check passes over deferred fields, so the image answers
                // an incremental response's initial part, and its operation
                // fetches. A streamed list is no deferred field: the check
                // walks it, and the image answers every item the stream placed.
                let initial = oracle.parts.count == 1 ? expected : try Oracle.leaves(of: oracle.streamedResponse(), plan: secondPlan)
                expectSame(Oracle.leaves(of: second.root, plan: secondPlan), initial, "from the image")
            }
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
        store.log = nil
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

    /// The streamed cases, each with the links its list holds once every
    /// part landed, in order, whatever order the parts came in.
    nonisolated static let streamedCases: [(name: String, list: String, keys: [String])] = [
        ("tests/character-streamed", "Character:1", ["Episode:1", "Episode:2", "Episode:3"]),
        ("tests/character-streamed-pending", "Character:1", ["Episode:1", "Episode:2", "Episode:3"]),
        ("tests/character-streamed-unordered", "Character:1", ["Episode:1", "Episode:2", "Episode:3"]),
        ("tests/character-streamed-failed", "Character:1", ["Episode:1"]),
        ("tests/notes-streamed", "Character:1:__TestStreamedNotes_notes_connection", ["Character:1:notes(first:2):edges:0", "Character:1:notes(first:2):edges:1"]),
    ]

    @Test("a streamed list holds its items in order at their indices once its stream completes, a failed stream's errors sit beside the list, and a streamed connection holds its edges and the deferred page info", arguments: streamedCases.map(\.name))
    func aStreamedListGrowsInItsSlot(_ name: String) async throws {
        let entry = try #require(Spec.manifest.cases.first { $0.name == name })
        let expected = try #require(Self.streamedCases.first { $0.name == name })
        let oracle = OracleCase(entry: entry)
        let operation = try OracleOperation.bind(entry)
        let store = Store()
        store.log = nil
        try await oracle.commit(operation, into: store)
        let record = try #require(store.existing(expected.list))
        let field = record.type == Registry.type("Character") ? "episode" : "edges"
        let slot = Registry.slot(record.type, field)
        guard case .refs(let list) = record.read(slot) else {
            Issue.record("\(expected.list).\(field) holds no list")
            return
        }
        #expect(list.map { $0?.key } == expected.keys)
        let errors = record.error(slot).map { [$0.message] } ?? []
        #expect(errors == (name == "tests/character-streamed-failed" ? ["episodes unavailable"] : []))
        StoreDump.expectMatches(store, oracle.dumpName)
        guard name == "tests/notes-streamed" else { return }
        let pageInfo = try #require(store.existing("Character:1:__TestStreamedNotes_notes_connection:pageInfo"))
        #expect(pageInfo.read(Registry.slot(pageInfo.type, "endCursor")) == .string("c2"))
        #expect(pageInfo.read(Registry.slot(pageInfo.type, "hasNextPage")) == .bool(true))
    }

    @Test("every operation the manifest's cases and scripts name has its document under spec/documents, equal to the text the compiler generated")
    func theDocumentsAgreeWithTheGeneratedText() throws {
        var documents: [String: String] = [:]
        for entry in Spec.manifest.cases {
            do {
                documents[entry.document] = try OracleOperation.bind(entry).text + "\n"
            } catch {
                Issue.record("\(entry.name): \(error)")
            }
        }
        // A script's operations are held to their documents as a case's are.
        for path in Spec.manifest.scripts {
            do {
                for reference in try Manifest.Script.load(path).operations {
                    documents["documents/\(reference.name).graphql"] = try OracleOperation.bind(reference.name, StepVariables(name: path, variables: reference.variables)).text + "\n"
                }
            } catch {
                Issue.record("\(path): \(error)")
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

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            continuation.finish()
        }
    }
}

extension Oracle {
    /// The first part of an incremental response with every later part's
    /// content placed at its path: the response the parts add up to. A
    /// deferred part's data merges into the object its path names; a
    /// streamed list's items are placed in the list, at the index Relay's
    /// shape and the June 2023 shape name, or after the last item for the
    /// 2024 shape, whose items arrive in order. Without `deferred`, the
    /// deferred parts are left out and the streamed items alone placed.
    static func merging(_ later: [Data], into first: Data, deferred: Bool = true) throws -> Data {
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
            // Relay's shape is one item at the top level of the part.
            let items = (object["incremental"] as? [[String: Any]]) ?? (object["path"] == nil ? [] : [object])
            for item in items {
                let announced = (item["id"] as? String).flatMap { pending[$0] }
                let path = (item["path"] as? [Any]) ?? announced ?? []
                if let elements = item["items"] as? [Any] {
                    if item["path"] != nil {
                        // The June 2023 shape: the path ends in the first item's index.
                        guard let first = path.last.flatMap(index) else {
                            throw OracleError(description: "a streamed part's path ends in no index")
                        }
                        for (offset, element) in elements.enumerated() {
                            tree["data"] = try placed(tree["data"] as Any, segments(path.dropLast()), first + offset, element)
                        }
                    } else {
                        // The 2024 shape: the items follow the last one the list holds.
                        for element in elements {
                            tree["data"] = try appended(tree["data"] as Any, segments(path), element)
                        }
                    }
                    continue
                }
                guard let data = item["data"] as? [String: Any] else { continue }
                if Self.isStream(item["label"]), let last = path.last.flatMap(index) {
                    // Relay's streamed item: one item, the path ending in its index.
                    tree["data"] = try placed(tree["data"] as Any, segments(path.dropLast()), last, data)
                    continue
                }
                guard deferred else { continue }
                tree["data"] = try merged(tree["data"] as Any, segments(path), data)
            }
        }
        tree.removeValue(forKey: "pending")
        tree.removeValue(forKey: "hasNext")
        return try JSONSerialization.data(withJSONObject: tree)
    }

    /// Whether a part's label is a stream's, as the compiler names it.
    private static func isStream(_ label: Any?) -> Bool {
        (label as? String)?.contains("$stream$") == true
    }

    /// A path segment as a list index, when it is a number.
    private static func index(_ segment: Any) -> Int? {
        guard !(segment is String), let number = segment as? NSNumber else { return nil }
        return number.intValue
    }

    private static func segments(_ path: some Collection<Any>) -> [String] {
        path.map { "\($0)" }
    }

    private static func merged(_ node: Any, _ path: [String], _ data: [String: Any]) throws -> Any {
        try walked(node, path) { node in
            guard var object = node as? [String: Any] else { throw OracleError(description: "a part lands on something that is not an object") }
            for (key, value) in data { object[key] = value }
            return object
        }
    }

    /// The list at `path` with `element` at `index`, extended with nulls to
    /// reach it.
    private static func placed(_ node: Any, _ path: [String], _ index: Int, _ element: Any) throws -> Any {
        try walked(node, path) { node in
            guard var list = node as? [Any] else { throw OracleError(description: "a streamed item lands on something that is not a list") }
            while list.count <= index { list.append(NSNull()) }
            list[index] = element
            return list
        }
    }

    /// The list at `path` with `element` after its last item.
    private static func appended(_ node: Any, _ path: [String], _ element: Any) throws -> Any {
        try walked(node, path) { node in
            guard var list = node as? [Any] else { throw OracleError(description: "a streamed item lands on something that is not a list") }
            list.append(element)
            return list
        }
    }

    /// The tree with the node at `path` replaced by what `change` makes of it.
    private static func walked(_ node: Any, _ path: [String], _ change: (Any) throws -> Any) throws -> Any {
        guard let head = path.first else { return try change(node) }
        let rest = Array(path.dropFirst())
        if var object = node as? [String: Any], let child = object[head] {
            object[head] = try walked(child, rest, change)
            return object
        }
        if var array = node as? [Any], let index = Int(head), array.indices.contains(index) {
            array[index] = try walked(array[index], rest, change)
            return array
        }
        throw OracleError(description: "a part's path names \(head), which the response does not have")
    }
}
