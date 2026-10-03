import Baton
import BatonSpec
import Foundation
import Testing

/// A recorded response, the plan that reads it, and where it hangs.
struct OracleCase: Sendable, CustomTestStringConvertible {
    enum Root: Sendable {
        case query, mutation, subscription

        var key: String {
            switch self {
            case .query: Store.rootKey
            case .mutation: Store.mutationRootKey
            case .subscription: Store.subscriptionRootKey
            }
        }

        @MainActor func record(in store: Store) -> Record {
            switch self {
            case .query: store.root
            case .mutation: store.mutationRoot
            case .subscription: store.subscriptionRoot
            }
        }
    }

    let name: String
    let response: Data
    let plan: ResolvedSelection
    let root: Root
    /// The leaves an optimistic layer overrides, and the value they show:
    /// one leaf, or several aliases of one storage key.
    let override: (paths: [String], value: LeafValue)
    /// Whether the image is read back: it keeps what hangs off the query
    /// root only.
    let persisted: Bool
    /// Whether the response answers every field the plan selects, so that
    /// the availability check passes on it.
    let complete: Bool

    var testDescription: String { name }

    init<Op: Baton.Operation>(_ name: String, _ response: Data, _ operation: Op, root: Root = .query, override: ([String], LeafValue), complete: Bool = true) {
        self.name = name
        self.response = response
        plan = Op.plan.resolve(operation.variables)
        self.root = root
        self.override = override
        persisted = root == .query
        self.complete = complete
    }

    static let all: [OracleCase] = [
        OracleCase("rickandmorty/characters-page-1", fixtureData, Fixture(page: 1), override: (["characters.info.count"], .int(1))),
        OracleCase("rickandmorty/character-episodes-9", Spec.data("rickandmorty/character-episodes-9.json"), TestEpisodesQuery(id: "9"), override: (["character.episode.0.name"], .string("Pickle Rick Redux"))),
        OracleCase("rickandmorty/character-header-9", Spec.data("rickandmorty/character-header-9.json"), TestHeaderQuery(id: "9"), override: (["character.name"], .string("Director"))),
        OracleCase("tests/character-errors", fixture("character-errors"), TestProfileQuery(id: "1"), override: (["character.species"], .string("Cyborg"))),
        OracleCase("tests/character-deferred-1", fixture("character-deferred-1"), TestProfileQuery(id: "1"), override: (["character.species"], .string("Cyborg"))),
        OracleCase("tests/character-deferred-1-pending", fixture("character-deferred-1-pending"), TestProfileQuery(id: "1"), override: (["character.species"], .string("Cyborg"))),
        OracleCase("tests/character-name-hidden", fixture("character-name-hidden"), TestStrictQuery(id: "1"), override: (["character.species"], .string("Cyborg"))),
        OracleCase("tests/characters-7-8", fixture("characters-7-8"), TestList(page: 1), override: (["characters.results.1.name"], .string("Rick Prime")), complete: false),
        OracleCase("tests/characters-with-gaps", fixture("characters-with-gaps"), TestList(page: 1), override: (["characters.results.2.name"], .string("Rick Prime")), complete: false),
        OracleCase("tests/notes-page-1", notesPage(1), TestNotesQuery(id: "1"), override: (["character.name"], .string("Rick Prime"))),
        OracleCase("tests/notes-page-2", notesPage(2), TestNotesPaginationQuery(count: 2, cursor: "c2", id: "1"), override: (["node.notes.edges.0.node.text"], .string("Get Schwiftier"))),
        OracleCase("tests/notes-page-3", notesPage(3), TestNotesPaginationQuery(count: 2, cursor: "c4", id: "1"), override: (["node.notes.edges.0.node.text"], .string("Get Schwiftier"))),
        OracleCase("tests/recent-notes-page-1", fixture("recent-notes-page-1"), TestRecentNotesQuery(id: "1"), override: (["character.notes.edges.1.node.text"], .string("Pickle Morty"))),
        OracleCase("tests/recent-notes-page-2", fixture("recent-notes-page-2"), TestRecentNotesPaginationQuery(count: 2, cursor: "c4", id: "1"), override: (["node.notes.pageInfo.startCursor"], .string("c0"))),
        OracleCase("tests/recent-notes-page-3", fixture("recent-notes-page-3"), TestRecentNotesPaginationQuery(count: 1, cursor: "c2", id: "1"), override: (["node.notes.edges.0.cursor"], .string("c0"))),
        OracleCase("tests/notes-refetch", fixture("notes-refetch"), TestNotesPaginationQuery(count: 2, id: "1"), override: (["node.name"], .string("Rick Prime"))),
        OracleCase("tests/add-note-node-n7", fixture("add-note-node-n7"), TestAddNoteNode(characterId: "1", text: "Node appended", connections: []), root: .mutation, override: (["addNote.note.text"], .string("Edited"))),
        OracleCase("tests/add-note-node-n0", fixture("add-note-node-n0"), TestAddNoteNodeFirst(characterId: "1", text: "Node first", connections: []), root: .mutation, override: (["addNote.note.text"], .string("Edited"))),
        OracleCase("tests/keys-1", fixture("keys-1"), TestKeys(id: "7", name: "Rick"), override: (["characters.info.count"], .int(2))),
        OracleCase("tests/search-1", fixture("search-1"), TestSearch(name: "1"), override: (["search.1.dimension"], .string("Dimension C-138")), complete: false),
        OracleCase("tests/search-origins-1", fixture("search-origins-1"), TestSearchOrigins(name: "1"), override: (["search.0.origin.name"], .string("Earth (C-138)")), complete: false),
        OracleCase("tests/set-favorite-1", fixture("set-favorite-1"), TestSetFavorite(id: "1", favorite: true), root: .mutation, override: (["setFavorite.character.favorite"], .bool(false))),
        OracleCase("tests/rename-1", fixture("rename-1"), TestRename(id: "1", name: "Rick Prime"), root: .mutation, override: (["rename.character.name"], .string("Rick Two"))),
        OracleCase("tests/add-note-n9", fixture("add-note-n9"), TestAddNote(characterId: "1", text: "Appended", connections: []), root: .mutation, override: (["addNote.noteEdge.node.text"], .string("Edited"))),
        OracleCase("tests/add-note-n9-pending", fixture("add-note-n9-pending"), TestAddNote(characterId: "1", text: "Pending", connections: []), root: .mutation, override: (["addNote.noteEdge.node.text"], .string("Edited"))),
        OracleCase("tests/add-note-n0", fixture("add-note-n0"), TestAddNoteFirst(characterId: "1", text: "First", connections: []), root: .mutation, override: (["addNote.noteEdge.cursor"], .string("c00"))),
        OracleCase("tests/remove-note-n2", fixture("remove-note-n2"), TestRemoveNote(id: "n2", connections: []), root: .mutation, override: (["removeNote.removedNoteId", "removeNote.deleted"], .string("n3"))),
        OracleCase("tests/note-added-1", fixture("note-added-1"), TestNoteAdded(characterId: "1", connections: []), root: .subscription, override: (["noteAdded.noteEdge.node.text"], .string("Edited"))),
        OracleCase("tests/character-origin-null", fixture("character-origin-null"), TestProfileQuery(id: "1"), override: (["character.species"], .string("Cyborg"))),
        OracleCase("tests/character-errors-answered", fixture("character-errors-answered"), TestProfileQuery(id: "1"), override: (["character.species"], .string("Cyborg"))),
        OracleCase("tests/negative-error-index", fixture("negative-error-index"), TestList(page: 1), override: (["characters.results.0.name"], .string("Rick Prime")), complete: false),
        OracleCase("tests/float-error-index", fixture("float-error-index"), TestList(page: 1), override: (["characters.results.0.name"], .string("Rick Prime")), complete: false),
        OracleCase("tokenizer/response", Spec.data("tokenizer/response.json"), TestTokenizerQuery(), override: (["tokenizer.text"], .string("overridden"))),
        OracleCase("tests/note-added-2", fixture("note-added-2"), TestNoteAdded(characterId: "1", connections: []), root: .subscription, override: (["noteAdded.noteEdge.node.text"], .string("Edited"))),
    ]
}

@MainActor
@Suite("The response is the oracle", .timeLimit(.minutes(1)))
struct OracleTests {
    @Test("the store reads back every leaf of the response, after the commit as its dump in spec/ says, from the image in a second store, and under a layer that overrides one leaf", arguments: OracleCase.all)
    func theStoreAgreesWithTheResponse(_ oracle: OracleCase) async throws {
        let expected = try Oracle.leaves(of: oracle.response, plan: oracle.plan)
        #expect(!expected.isEmpty)
        let image = TemporaryImage()
        let persistence = Persistence(url: image.url)
        let store = Store(persistence: oracle.persisted ? persistence : nil)
        store.reportMissing = nil
        store.commit(try Ingest.normalize(oracle.response, plan: oracle.plan, rootKey: oracle.root.key))
        expectSame(Oracle.leaves(of: oracle.root.record(in: store), plan: oracle.plan), expected, "after the commit")
        StoreDump.expectMatches(store, oracle.name)

        if oracle.persisted {
            await persistence.flush()
            let second = Store(persistence: Persistence(url: image.url))
            second.reportMissing = nil
            let environment = Environment(transport: SilentTransport(), store: second)
            let answered = environment.store.check(oracle.plan)
            if oracle.complete { #expect(answered, "the image answers the plan") }
            expectSame(Oracle.leaves(of: second.root, plan: oracle.plan), expected, "from the image")
        }

        let (paths, value) = oracle.override
        var edited = oracle.response
        var overridden = expected
        for path in paths {
            edited = try Oracle.replacing(path, with: value, in: edited)
            overridden = overridden.replacing(path, with: value)
        }
        let layer = store.applyOptimistic(try Ingest.normalize(edited, plan: oracle.plan, rootKey: oracle.root.key))
        expectSame(Oracle.leaves(of: oracle.root.record(in: store), plan: oracle.plan), overridden, "under the layer")
        store.revertOptimistic(layer)
        expectSame(Oracle.leaves(of: oracle.root.record(in: store), plan: oracle.plan), expected, "after the layer is reverted")
    }

    @Test("a deferred response reads back as the first part with every later part merged in at its path", arguments: [
        ("character-deferred-1", "character-deferred-2"),
        ("character-deferred-1-pending", "character-deferred-2-pending"),
    ])
    func deferredPartsAgreeWithTheResponse(_ parts: (String, String)) async throws {
        let first = fixture(parts.0)
        let second = fixture(parts.1)
        let environment = Environment(transport: Parts([first, second]))
        environment.store.reportMissing = nil
        let operation = TestProfileQuery(id: "1")
        try await environment.fetch(operation)

        let plan = TestProfileQuery.plan.resolve(operation.variables)
        let merged = try Oracle.merging([second], into: first)
        let expected = try Oracle.leaves(of: merged, plan: plan)
        #expect(expected.contains { $0.path == "character.episode.1.name" }, "the deferred part's leaves are expected")
        expectSame(Oracle.leaves(of: environment.store.root, plan: plan), expected, "after both parts")
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
