@_spi(Generated) import Baton
import BatonInspector
import BatonSpec
import BatonTesting
import Foundation
import Observation
import Testing

/// Holds every request until the test answers it, so the window between an
/// optimistic apply and the server's answer can be observed.
final class GatedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Data, any Error>] = []

    var pending: Int { lock.withLock { waiting.count } }

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        Self.once {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.withLock { self.waiting.append(continuation) }
            }
        }
    }

    func respond(_ data: Data) {
        lock.withLock { waiting.removeFirst() }.resume(returning: data)
    }

    func fail(_ error: any Error) {
        lock.withLock { waiting.removeFirst() }.resume(throwing: error)
    }
}

/// A transport that answers when told and, as `URLSession` does, fails the
/// request with a cancellation when the task that made it is cancelled.
final class CancellableGate: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Data, any Error>?

    var pending: Bool { lock.withLock { waiting != nil } }

    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        Self.once { try await self.answer() }
    }

    private func answer() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiting = continuation }
            }
        } onCancel: {
            lock.withLock { () -> CheckedContinuation<Data, any Error>? in
                defer { waiting = nil }
                return waiting
            }?.resume(throwing: CancellationError())
        }
    }

    func respond(_ data: Data) {
        lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            defer { waiting = nil }
            return waiting
        }?.resume(returning: data)
    }
}

@MainActor
@Suite("Writes", .timeLimit(.minutes(1)))
struct WriteTests {
    /// A store holding the first page of the fixture through the list plan.
    func seededStore() throws -> Store {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        return store
    }

    func favorite(_ store: Store, _ key: String) throws -> TestFavorite_character {
        TestFavorite_character(anchor: Anchor(record: try #require(store.existing(key)), variables: .none, store: store))
    }

    /// Normalizes an optimistic response the way `Environment.mutate` does.
    func layerChanges<Op: Baton.Operation>(_ operation: Op, _ optimistic: Variable, in store: Store) throws -> ChangeSet {
        let json = Data(("{\"data\":" + optimistic.json + "}").utf8)
        return try Ingest.normalize(json, plan: Op.plan.resolve(operation.variables, in: store.keys), rootKey: Store.mutationRootKey)
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

    @Test("the data a mutation returns stays readable through a collection while the environment keeps the mutation, and not after")
    func mutationResultLives() async throws {
        for bufferSize in [10, 0] {
            let environment = Environment(transport: RecordedTransport([TestRename.name: fixture("rename-1")]), store: Store(releaseBufferSize: bufferSize))
            let data = try await environment.mutate(TestRename(id: "1", name: "Rick Prime"))
            #expect(data.rename?.character?.name == "Rick Prime")
            environment.store.collect()
            if bufferSize > 0 {
                #expect(data.rename?.character?.name == "Rick Prime", "the completed mutation keeps its payload")
            } else {
                #expect(data.rename == nil, "with a buffer of zero nothing is kept, and the payload is collected")
            }
        }
    }

    @Test("mutations push no released query out of the release buffer, and a mutation made again takes the place it had")
    func mutationsKeepTheirOwnPlaces() async throws {
        let transport = RecordedTransport([TestList.name: fixtureData, TestRename.name: fixture("rename-1"), TestSetFavorite.name: fixture("set-favorite-1")])
        let environment = Environment(transport: transport, store: Store(releaseBufferSize: 2))
        let list = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        let listRetention = list.retain()
        await list.settle()
        _ = consume listRetention

        let favorited = try await environment.mutate(TestSetFavorite(id: "1", favorite: true))
        for _ in 0..<3 {
            _ = try await environment.mutate(TestRename(id: "1", name: "Rick Prime"))
        }
        environment.store.collect()
        #expect(environment.store.existing("Character:2") != nil, "the released list keeps its records")
        let again = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(again === list)
        await again.settle()
        #expect(transport.requestCount == 5, "the list once and four mutations, with no refetch")
        #expect(favorited.setFavorite?.character?.favorite == true, "the three renames took one place, so the earlier mutation keeps its payload")
    }

    @Test("an earlier completion of a mutation with other variables keeps the records its own selection reaches through a collection")
    func mutationWithOtherVariablesKeepsItsOwnPlace() async throws {
        let transport = RecordedTransport { request in
            if case .bool(true)? = request.variables["withOrigin"] { return fixture("rename-1-origin") }
            return fixture("rename-1")
        }
        let environment = Environment(transport: transport)
        environment.log = nil
        let first = try await environment.mutate(TestRenameWithOrigin(id: "1", name: "Rick Prime", withOrigin: true))
        _ = try await environment.mutate(TestRenameWithOrigin(id: "1", name: "Rick Prime", withOrigin: false))
        environment.store.collect()
        #expect(environment.store.existing("Location:L1") != nil, "only the first completion's selection reaches the origin")
        #expect(first.rename?.character?.origin?.name == "Earth (C-137)")
    }

    @Test("a mutation pushed out of the buffer has its payload collected without a call to collect")
    func mutationPushedOutIsCollected() async throws {
        let environment = Environment(transport: RecordedTransport([TestRename.name: fixture("rename-1"), TestSetFavorite.name: fixture("set-favorite-1")]), store: Store(releaseBufferSize: 1))
        let renamed = try await environment.mutate(TestRename(id: "1", name: "Rick Prime"))
        let collections = environment.store.collections
        let favorited = try await environment.mutate(TestSetFavorite(id: "1", favorite: true))
        await until { environment.store.collections > collections }
        #expect(renamed.rename == nil, "the rename was pushed out and its payload collected")
        #expect(favorited.setFavorite?.character?.favorite == true)
    }

    @Test("a mutation that only spreads a fragment on the mutation type reads its payload through the fragment")
    func mutationFragmentReadsThePayload() async throws {
        let environment = Environment(transport: RecordedTransport([TestRenameThroughFragment.name: fixture("rename-1")]))
        let data = try await environment.mutate(TestRenameThroughFragment(id: "1", name: "Rick Prime"))
        #expect(data.testRenamePayload.rename?.character?.name == "Rick Prime")
    }

    @Test("a mutation whose caller stops waiting still commits the payload the server sends")
    func mutationOutlivesItsCaller() async throws {
        let transport = CancellableGate()
        let environment = Environment(transport: transport, store: try seededStore())
        let caller = Task { try await environment.mutate(TestRename(id: "1", name: "Rick Prime")) }
        await until { transport.pending }
        caller.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.pending, "the request was not cancelled with its caller")
        transport.respond(fixture("rename-1"))
        let renamed = try await caller.value
        #expect(renamed.rename?.character?.name == "Rick Prime", "the caller that stopped waiting is handed the result")
        let rick = try #require(environment.store.existing("Character:1"))
        #expect(rick.read(Registry.slot(rick.type, "name")) == .string("Rick Prime"))
    }

    @Test("a mutation's root field is keyed without its input, so a call with a new input numbers no new slot")
    func mutationRootKeys() throws {
        let mutation = Registry.type("Mutation")
        let keys = Keys()
        let first = TestRename.plan.resolve(TestRename(id: "1", name: "Rick Prime").variables, in: keys)
        let count = Registry.slotCount(mutation)
        let second = TestRename.plan.resolve(TestRename(id: "1", name: "a name no other test sends").variables, in: keys)
        #expect(Registry.slotCount(mutation) == count)
        #expect(keys.count(on: mutation) == 0, "the store numbers no rendering of it either")
        #expect(first.variant(for: mutation).fields.map(\.slot) == second.variant(for: mutation).fields.map(\.slot))
    }

    @Test("an optimistic layer's keys stay while the layer is applied and go when it lifts")
    func anOptimisticLayersKeysStayWhileApplied() throws {
        let store = Store()
        store.log = nil
        let query = Registry.type("Query")
        let header = TestHeaderQuery(id: "9")
        // No mutation renders a key, its root field being keyed without its
        // input, so the layer is a lookup's response applied as one. The
        // resolution goes with the statement: only the layer names the key.
        let layer = store.applyOptimistic(try Ingest.normalize(Spec.data("rickandmorty/character-header-9.json"), plan: TestHeaderQuery.plan.resolve(header.variables, in: store.keys)))
        store.collect()
        #expect(store.keys.count(on: query) == 1, "the applied layer keeps the key it writes")
        do {
            let data = TestHeaderQuery.Data(anchor: Anchor(record: store.root, variables: header.variables, store: store))
            #expect(data.character?.testHeader.name == "Agency Director", "the layer's value reads under its key")
        }

        store.revertOptimistic(layer)
        #expect(store.optimisticLayers.isEmpty)
        store.collect()
        #expect(store.keys.count(on: query) == 0, "the lifted layer's key is freed")
        #expect(store.root.renderedKeyCount == 0)
    }

    @Test("a server payload commits under a live layer and the layer stays on top until it resolves")
    func layerRebasesUnderCommits() throws {
        let store = try seededStore()
        let rick = try favorite(store, "Character:1")
        let morty = try favorite(store, "Character:2")
        #expect(rick.name == "Rick Sanchez")

        let rename = TestRename(id: "1", name: "Rick Prime")
        let layer = store.applyOptimistic(try layerChanges(rename, TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable, in: store))
        #expect(rick.name == "Rick Prime")

        // The list refreshes meanwhile: the server still calls him Rick Sanchez
        // and has renamed Morty. The layer stays on top of Rick; Morty's change
        // comes through.
        let refreshed = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\"", with: "\"name\":\"Morty C-137\"")
        let changed = store.commit(try Ingest.normalize(Data(refreshed.utf8), plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        #expect(rick.name == "Rick Prime")
        #expect(morty.name == "Morty C-137")
        #expect(changed == 1, "only Morty's name changed in the end")

        // The mutation's own answer replaces the layer; nothing visible changes.
        let answer = fixture("rename-1")
        let net = store.commit(try Ingest.normalize(answer, plan: TestRename.plan.resolve(rename.variables, in: store.keys), rootKey: Store.mutationRootKey), replacingOptimistic: layer)
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
        let first = store.applyOptimistic(try layerChanges(rename, TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Prime"))).variable, in: store))
        #expect(counter.fired == 1, "the apply changed the name")

        track()
        let answer = fixture("rename-1")
        store.commit(try Ingest.normalize(answer, plan: TestRename.plan.resolve(rename.variables, in: store.keys), rootKey: Store.mutationRootKey), replacingOptimistic: first)
        #expect(counter.fired == 1, "the answer agreed with the layer: no notification")

        let second = store.applyOptimistic(try layerChanges(TestRename(id: "1", name: "Rick Two"), TestRename.OptimisticResponse(rename: .init(character: .init(id: "1", name: "Rick Two"))).variable, in: store))
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
        store.commit(try Ingest.normalize(payload, plan: TestSearch.plan.resolve(variables, in: store.keys)))

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
        store.commit(try Ingest.normalize(payload, plan: TestSearchOrigins.plan.resolve(variables, in: store.keys)))

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
        store.log = nil
        let list = fixture("characters-7-8")
        store.commit(try Ingest.normalize(list, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))

        let variables = TestNode(id: "8").variables
        #expect(store.check(TestNode.plan.resolve(variables, in: store.keys)) != .miss, "the id index satisfies the lookup")
        let data = TestNode.Data(anchor: Anchor(record: store.root, variables: variables, store: store))
        #expect(data.node?.asCharacter?.name == "Adjudicator Rick")
        #expect(data.node?.asEpisode == nil)
        #expect(store.check(TestNode.plan.resolve(TestNode(id: "999").variables, in: store.keys)) == .miss)
    }

    @Test("a query's response committed by hand leaves the store as a fetch of the same response does, and a storeOnly handle answers from it")
    func aQueryPayloadCommittedByHandMatchesAFetch() async throws {
        let fetched = Environment(transport: RecordedTransport([Fixture.name: fixtureData]))
        try await fetched.fetch(Fixture(page: 1))

        let committed = Environment(transport: SilentTransport())
        try await committed.commitPayload(Fixture(page: 1), fixtureData)
        #expect(StoreExport.text(of: committed.store) == StoreExport.text(of: fetched.store))

        let handle = committed.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the store to answer, got \(handle.phase)")
            return
        }
        #expect(data.characters?.results?.first?.name == "Rick Sanchez")
        #expect(data.characters?.info?.count == 826)
    }

    @Test("a payload that carries one field of one entity writes that field and leaves everything else as it was")
    func aPartialPayloadWritesOnlyWhatItCarries() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        try await environment.commitPayload(Fixture(page: 1), fixtureData)
        let before = StoreExport.text(of: environment.store).split(separator: "\n")

        let payload = Data(#"{"data":{"character":{"id":"1","name":"Rick Prime"}}}"#.utf8)
        try await environment.commitPayload(TestHeaderQuery(id: "1"), payload)
        let after = StoreExport.text(of: environment.store).split(separator: "\n")

        let rick = try #require(before.first { $0.hasPrefix(#"  "Character:1": "#) })
        #expect(rick.contains(#""name": "Rick Sanchez""#))
        let renamed = rick.replacingOccurrences(of: #""name": "Rick Sanchez""#, with: #""name": "Rick Prime""#)
        let changed = Set(before).symmetricDifference(Set(after))
        let untouched = changed.filter { !$0.hasPrefix(#"  "client:root": "#) }
        #expect(untouched == [rick, Substring(renamed)], "only Rick's name changed among the records, besides the root's new link")
        #expect(after.count == before.count, "no record was added or removed")
    }

    @Test("a mutation's payload committed by hand applies its @appendEdge to a connection the store holds")
    func aMutationPayloadCommittedByHandAppendsItsEdge() async throws {
        let environment = Environment(transport: notesTransport())
        environment.log = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character?.testNotes)
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])

        let mutation = TestAddNote(characterId: "1", text: "Appended", connections: [character.notes.connectionID])
        try await environment.commitPayload(mutation, fixture("add-note-n9"))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Appended"])
        let roots = StoreExport.text(of: environment.store).split(separator: "\n")
        #expect(roots.contains { $0.hasPrefix(#"  "client:root:mutation": "#) && $0.contains("addNote") }, "the payload hangs off the mutation root")
        #expect(!roots.contains { $0.hasPrefix(#"  "client:root": "#) && $0.contains("addNote") })
        _ = consume retention
    }

    @Test("a subscription's event committed by hand lands at the subscription root and appends through @appendEdge")
    func aSubscriptionEventCommittedByHandLandsAtTheSubscriptionRoot() async throws {
        let environment = Environment(transport: notesTransport())
        environment.log = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character?.testNotes)

        let subscription = TestNoteAdded(characterId: "1", connections: [character.notes.connectionID])
        try await environment.commitPayload(subscription, fixture("note-added-1"))
        #expect(character.notes.nodes.map(\.text).last == "Live from the garage")

        let store = environment.store
        let event = TestNoteAdded.Data(anchor: Anchor(record: store.subscriptionRoot, variables: subscription.variables, store: store))
        #expect(event.noteAdded?.noteEdge?.node?.text == "Live from the garage")
        let roots = StoreExport.text(of: store).split(separator: "\n")
        #expect(roots.contains { $0.hasPrefix(#"  "client:root:subscription": "#) && $0.contains("noteAdded") })
        #expect(!roots.contains { $0.hasPrefix(#"  "client:root": "#) && $0.contains("noteAdded") }, "nothing hangs off the query root")
        _ = consume retention
    }

    @Test("under @throwOnFieldError a payload committed by hand throws its uncaught field errors, and one without errors does not")
    func aStrictPayloadCommittedByHandThrowsItsFieldErrors() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        let thrown = await #expect(throws: FieldErrors.self) {
            try await environment.commitPayload(TestStrictQuery(id: "1"), fixture("character-name-hidden"))
        }
        #expect(thrown?.errors.map(\.path) == ["character.name"])
        #expect(environment.store.existing("Character:1") != nil, "the payload is committed regardless")

        try await environment.commitPayload(TestStrictQuery(id: "1"), fixture("character-name-shown"))
        let handle = environment.handle(for: TestStrictQuery(id: "1"), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        #expect(data.character?.name == "Rick Sanchez")
    }

    @Test("a payload committed by hand from a task cancelled before it awaits is still committed")
    func aCancelledCallerStillCommitsItsPayload() async throws {
        let environment = Environment(transport: SilentTransport())
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            try await environment.commitPayload(Fixture(page: 1), fixtureData)
        }
        try await caller.value
        let handle = environment.handle(for: Fixture(page: 1), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the payload in the store, got \(handle.phase)")
            return
        }
        #expect(data.characters?.results?.first?.name == "Rick Sanchez")
    }
}
