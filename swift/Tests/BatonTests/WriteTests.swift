import Baton
import Foundation
import Observation
import Testing

/// Holds every request until the test answers it, so the window between an
/// optimistic apply and the server's answer can be observed.
final class GatedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Data, any Error>] = []

    var pending: Int { lock.withLock { waiting.count } }

    func execute(_ request: Request) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    func respond(_ data: Data) {
        lock.withLock { waiting.removeFirst() }.resume(returning: data)
    }

    func fail(_ error: any Error) {
        lock.withLock { waiting.removeFirst() }.resume(throwing: error)
    }
}

@MainActor
@Suite("Writes", .timeLimit(.minutes(1)))
struct WriteTests {
    /// A store holding the first page of the fixture through the list plan.
    func seededStore() throws -> Store {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        return store
    }

    func favorite(_ store: Store, _ key: String) throws -> TestFavorite_character {
        TestFavorite_character(anchor: Anchor(record: try #require(store.existing(key)), variables: .none, store: store))
    }

    /// Normalizes an optimistic response the way `Environment.mutate` does.
    func layerChanges<Op: Baton.Operation>(_ operation: Op, _ optimistic: Variable) throws -> ChangeSet {
        let json = Data(("{\"data\":" + optimistic.json + "}").utf8)
        return try Ingest.normalize(json, plan: Op.plan.resolve(operation.variables), rootKey: Store.mutationRootKey)
    }

    @Test("an optimistic response shows at once and is reverted when the server fails")
    func optimisticShowsAtOnceAndRevertsOnFailure() async throws {
        let transport = GatedTransport()
        let environment = Environment(transport: transport, store: try seededStore())
        let rick = try favorite(environment.store, "Character:1")
        #expect(rick.favorite == nil, "the list never fetched the field")

        let optimistic = TestSetFavorite.OptimisticResponse(setFavorite: .init(character: .init(id: "1", favorite: true)))
        let mutation = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true), optimistic: optimistic.variable) }
        await until { transport.pending != 0 }

        #expect(rick.favorite == true, "the layer is visible before the server answers")
        #expect(environment.store.optimisticLayers.count == 1)

        transport.fail(TransportError(statusCode: 500, body: "no"))
        await #expect(throws: TransportError.self) { try await mutation.value }
        #expect(rick.favorite == nil, "the failure reverted the layer")
        #expect(environment.store.optimisticLayers.isEmpty)
    }

    @Test("the server's answer replaces the layer in one batch and the mutation returns its data")
    func serverAnswerReplacesTheLayer() async throws {
        let transport = GatedTransport()
        let environment = Environment(transport: transport, store: try seededStore())
        let rick = try favorite(environment.store, "Character:1")

        let optimistic = TestSetFavorite.OptimisticResponse(setFavorite: .init(character: .init(id: "1", favorite: true)))
        let mutation = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true), optimistic: optimistic.variable) }
        await until { transport.pending != 0 }
        #expect(rick.favorite == true)

        transport.respond(fixture("set-favorite-1"))
        let data = try await mutation.value
        #expect(data.setFavorite?.character?.favorite == true)
        #expect(data.setFavorite?.character?.name == "Rick Sanchez")
        #expect(rick.favorite == true)
        #expect(environment.store.optimisticLayers.isEmpty)
        #expect(environment.store.mutationRoot !== environment.store.root)
    }

    @Test("a server payload commits under a live layer and the layer stays on top until it resolves")
    func layerRebasesUnderCommits() throws {
        let store = try seededStore()
        let rick = try favorite(store, "Character:1")
        let morty = try favorite(store, "Character:2")
        #expect(rick.name == "Rick Sanchez")

        let rename = TestRename(id: "1", name: "Rick Prime")
        let layer = store.applyOptimistic(try layerChanges(rename, TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable))
        #expect(rick.name == "Rick Prime")

        // The list refreshes meanwhile: the server still calls him Rick Sanchez
        // and has renamed Morty. The layer stays on top of Rick; Morty's change
        // comes through.
        let refreshed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let changed = store.commit(try Ingest.normalize(Data(refreshed.utf8), plan: TestList.plan.resolve(TestList(page: 1).variables)))
        #expect(rick.name == "Rick Prime")
        #expect(morty.name == "Morty C-137")
        #expect(changed == 1, "only Morty's name changed in the end")

        // The mutation's own answer replaces the layer; nothing visible changes.
        let answer = fixture("rename-1")
        let net = store.commit(try Ingest.normalize(answer, plan: TestRename.plan.resolve(rename.variables), rootKey: Store.mutationRootKey), replacingOptimistic: layer)
        #expect(net == 0)
        #expect(rick.name == "Rick Prime")
        #expect(store.optimisticLayers.isEmpty)
    }

    @Test("resolving or reverting a layer notifies only the slots whose value differs in the end")
    func netNotifications() throws {
        let store = try seededStore()
        let rick = try favorite(store, "Character:1")
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        func track() {
            withObservationTracking { _ = rick.name } onChange: { counter.fired += 1 }
        }

        track()
        let rename = TestRename(id: "1", name: "Rick Prime")
        let first = store.applyOptimistic(try layerChanges(rename, TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable))
        #expect(counter.fired == 1, "the apply changed the name")

        track()
        let answer = fixture("rename-1")
        store.commit(try Ingest.normalize(answer, plan: TestRename.plan.resolve(rename.variables), rootKey: Store.mutationRootKey), replacingOptimistic: first)
        #expect(counter.fired == 1, "the answer agreed with the layer: no notification")

        let second = store.applyOptimistic(try layerChanges(TestRename(id: "1", name: "Rick Two"), TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Two"))).variable))
        #expect(counter.fired == 2)
        #expect(rick.name == "Rick Two")

        track()
        store.revertOptimistic(second)
        #expect(counter.fired == 3, "the revert changed the name back")
        #expect(rick.name == "Rick Prime")
    }

    @Test("objects behind a union are keyed by their concrete type, whichever order the typename arrives in")
    func abstractObjectsKeyByTypename() throws {
        let store = Store()
        let payload = fixture("search-1")
        let variables = TestSearch(name: "1").variables
        store.commit(try Ingest.normalize(payload, plan: TestSearch.plan.resolve(variables)))

        #expect(store.existing("Character:1") != nil)
        #expect(store.existing("Location:1") != nil)
        #expect(store.existing("Episode:1") != nil)

        let data = TestSearch.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let results = try #require(data.search)
        #expect(results.count == 3)
        #expect(results[0].asCharacter?.name == "Rick Sanchez")
        #expect(results[0].asLocation == nil)
        #expect(results[1].asLocation?.dimension == "Dimension C-137")
        #expect(results[1].asCharacter == nil)
        #expect(results[2].asCharacter == nil && results[2].asLocation == nil)
    }

    @Test("an object behind a union is keyed by its type and id when both arrive after a link")
    func abstractIdentityArrivesAfterALink() throws {
        let store = Store()
        let payload = fixture("search-origins-1")
        let variables = TestSearchOrigins(name: "1").variables
        store.commit(try Ingest.normalize(payload, plan: TestSearchOrigins.plan.resolve(variables)))

        #expect(store.existing("Character:1") != nil)
        #expect(store.existing("Character:2") != nil)
        #expect(store.existing("Location:1") != nil)
        #expect(store.count == 6, "three entities and three roots")

        let data = TestSearchOrigins.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        let results = try #require(data.search)
        #expect(results.map { $0.recordID.key } == ["Character:1", "Character:2"])
        #expect(results[0].asCharacter?.origin?.name == "Earth (C-137)")
    }

    @Test("node(id:) finds a cached entity by id across types")
    func nodeLookup() throws {
        let store = Store()
        store.reportMissing = nil
        let list = fixture("characters-7-8")
        store.commit(try Ingest.normalize(list, plan: TestList.plan.resolve(TestList(page: 1).variables)))

        let variables = TestNode(id: "8").variables
        #expect(store.check(TestNode.plan.resolve(variables)), "the id index satisfies the lookup")
        let data = TestNode.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        #expect(data.node?.asCharacter?.name == "Adjudicator Rick")
        #expect(data.node?.asEpisode == nil)
        #expect(!store.check(TestNode.plan.resolve(TestNode(id: "999").variables)))
    }
}
