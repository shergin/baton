@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import Testing

/// A transport that answers the notes query with its first page and holds
/// every request after it until the test answers it, so a page load can be
/// watched in flight on the environment that made the handle.
final class GatedPages: Transport, Sendable {
    let gate = GatedTransport()

    func execute(_ request: Request) async throws -> Data {
        if request.operationName == TestNotesQuery.name { return notesPage(1) }
        return try await gate.execute(request)
    }
}

@MainActor
@Suite("Lists", .timeLimit(.minutes(1)))
struct ListTests {
    /// The notes query, fetched and held as a view on screen holds it: the
    /// retention keeps its root until the test lets it go.
    func seededEnvironment(_ transport: any Transport = notesTransport(), store: Store = Store()) async throws -> (Environment, TestNotes_character, Retention) {
        let environment = Environment(transport: transport, store: store)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the first page did not arrive") }
        return (environment, try #require(data.character?.testNotes), retention)
    }

    /// Lets the main actor turn a few times, so a collection pass a commit
    /// scheduled has run.
    func turns() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func counter(_ body: @escaping @MainActor () -> Void) -> (fired: () -> Int, track: () -> Void) {
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        func track() {
            withObservationTracking { body() } onChange: { counter.fired += 1 }
        }
        return ({ counter.fired }, track)
    }

    @Test("two pages merge into one connection, in order, with the page info of the last one")
    func pagesMerge() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])
        #expect(character.notes.totalCount == 5)
        #expect(character.notes.hasNext)
        #expect(character.notes.connectionID == "Character:1:__TestNotes_notes_connection")

        // The second page, as the pagination query delivers it.
        let variables = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c2")])
        environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables, in: environment.store.keys)))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel"])
        #expect(character.notes.hasNext)
        #expect(character.notes.pageInfo.endCursor == "c4")

        // The same page again changes nothing; a page after a stale cursor is ignored.
        let unchanged = environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables, in: environment.store.keys)))
        #expect(unchanged == 0)
        let stale = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c1")])
        environment.store.commit(try Ingest.normalize(notesPage(3), plan: TestNotesPaginationQuery.plan.resolve(stale, in: environment.store.keys)))
        #expect(character.notes.nodes.count == 4)
        withExtendedLifetime(retention) {}
    }

    @Test("refetching the first page replaces the merged list, and an equal page notifies nothing")
    func refetchReplaces() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        let (fired, track) = counter { _ = character.notes.nodes }
        let variables = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c2")])
        track()
        environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables, in: environment.store.keys)))
        #expect(fired() == 1, "the list grew")
        #expect(character.notes.nodes.count == 4)

        track()
        environment.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: environment.store.keys)))
        #expect(character.notes.nodes.count == 2, "a refetch without a cursor is the first page again")
        #expect(character.notes.pageInfo.endCursor == "c2")
        #expect(fired() == 2)

        track()
        environment.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: environment.store.keys)))
        #expect(fired() == 2, "the same first page again: same edges, no notification")
        withExtendedLifetime(retention) {}
    }

    @Test("loadNext fetches after the end cursor, appends, and is a no-op at the end")
    func loadNext() async throws {
        let transport = notesTransport()
        let (environment, character, retention) = try await seededEnvironment(transport)
        #expect(transport.requestCount == 1)

        try await character.notes.loadNext()
        #expect(transport.requestCount == 2)
        let request = transport.requests[1]
        #expect(request.operationName == "TestNotesPaginationQuery")
        #expect(request.variables["cursor"] == .string("c2"))
        #expect(request.variables["count"] == .int(2))
        #expect(request.variables["id"] == .string("1"))
        #expect(character.notes.nodes.count == 4)
        #expect(!character.notes.isLoadingNext)

        try await character.notes.loadNext(10)
        #expect(transport.requests[2].variables["cursor"] == .string("c4"))
        #expect(transport.requests[2].variables["count"] == .int(10))
        #expect(character.notes.nodes.count == 5)
        #expect(!character.notes.hasNext)

        try await character.notes.loadNext()
        #expect(transport.requestCount == 3, "nothing to load")

        // Each page fetched is dated on a root of its own, which nothing
        // retains and so waits in the release buffer; the connection keeps
        // its pages through the notes query's root.
        #expect(environment.store.rootCount == 3, "the notes query's root and the two pages' waiting in the buffer")
        environment.store.collect()
        #expect(character.notes.nodes.count == 5)
        #expect(environment.store.existing("Note:n5") != nil)
        withExtendedLifetime(retention) {}
    }

    @Test("a lens pages through the environment that made its handle, not another made later over the same store")
    func lensPagesThroughItsHandlesEnvironment() async throws {
        let transport = notesTransport()
        let (environment, character, retention) = try await seededEnvironment(transport)
        let later = RecordedTransport()
        let other = Environment(transport: later, store: environment.store)
        try await character.notes.loadNext()
        #expect(transport.requestCount == 2)
        #expect(later.requestCount == 0)
        #expect(character.notes.nodes.count == 4)
        withExtendedLifetime((other, retention)) {}
    }

    @Test("isLoadingNext is a client field on the connection record while the page is in flight")
    func loadingFlag() async throws {
        // The lens pages through the environment that made its handle, whose
        // transport holds the page until the test answers it.
        let transport = GatedPages()
        let gate = transport.gate
        let (environment, character, retention) = try await seededEnvironment(transport)
        #expect(!character.notes.isLoadingNext)
        let loading = Task { try await character.notes.loadNext() }
        await until { gate.pending != 0 }
        #expect(character.notes.isLoadingNext)
        gate.respond(notesPage(2))
        try await loading.value
        #expect(!character.notes.isLoadingNext)
        #expect(character.notes.nodes.count == 4)
        #expect(environment.store.rootCount == 2, "the notes query's root and the page's, dated and waiting in the buffer")
        withExtendedLifetime(retention) {}
    }

    @Test("the loading flag notifies its readers when a page load sets it and again when the load clears it")
    func loadingFlagNotifies() async throws {
        let transport = GatedPages()
        let gate = transport.gate
        let (environment, character, retention) = try await seededEnvironment(transport)
        let (fired, track) = counter { _ = character.notes.isLoadingNext }
        track()
        let loading = Task { try await character.notes.loadNext() }
        await until { gate.pending != 0 }
        #expect(fired() == 1, "the flag was set")
        #expect(character.notes.isLoadingNext)

        track()
        gate.respond(notesPage(2))
        try await loading.value
        #expect(fired() == 2, "the flag was cleared")
        #expect(!character.notes.isLoadingNext)
        #expect(environment.store.rootCount == 2, "the notes query's root and the page's, dated and waiting in the buffer")
        withExtendedLifetime(retention) {}
    }

    @Test("@appendEdge and @prependEdge insert the payload's edge into the connection named by the variable")
    func edgeDirectives() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        let connections = [character.notes.connectionID]
        let (fired, track) = counter { _ = character.notes.nodes }

        track()
        let appended = TestAddNote(characterId: "1", text: "Appended", connections: connections)
        let payload = fixture("add-note-n9")
        environment.store.commit(try Ingest.normalize(payload, plan: TestAddNote.plan.resolve(appended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Appended"])
        #expect(fired() == 1)

        let prepended = TestAddNoteFirst(characterId: "1", text: "First", connections: connections)
        let first = fixture("add-note-n0")
        environment.store.commit(try Ingest.normalize(first, plan: TestAddNoteFirst.plan.resolve(prepended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["First", "Wubba lubba dub dub", "Portal gun needs charging", "Appended"])

        // The same node again is not inserted twice.
        environment.store.commit(try Ingest.normalize(payload, plan: TestAddNote.plan.resolve(appended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.count == 4)
        withExtendedLifetime(retention) {}
    }

    @Test("an optimistic @appendEdge shows at once, survives a page under it, and is replaced by the server's edge")
    func optimisticEdge() async throws {
        let gate = GatedTransport()
        let (environment, character, retention) = try await seededEnvironment()
        let mutating = Environment(transport: gate, store: environment.store)
        let connections = [character.notes.connectionID]
        let optimistic = TestAddNote.OptimisticResponse(addNote: .init(noteEdge: .init(node: .init(id: "client:new", text: "Pending"))))

        let mutation = Task { try await mutating.mutate(TestAddNote(characterId: "1", text: "Pending", connections: connections), optimistic: optimistic.variable) }
        await until { gate.pending != 0 }
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Pending"])

        // A page arrives while the layer is live: it lands under the optimistic edge.
        let variables = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c2")])
        environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables, in: environment.store.keys)))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel", "Pending"])

        gate.respond(fixture("add-note-n9-pending"))
        _ = try await mutation.value
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel", "Pending"])
        #expect(character.notes.nodes.last?.id == "n9")
        #expect(environment.store.optimisticLayers.isEmpty)

        // A failure reverts the optimistic edge.
        let failing = Task { try await mutating.mutate(TestAddNote(characterId: "1", text: "Doomed", connections: connections), optimistic: TestAddNote.OptimisticResponse(addNote: .init(noteEdge: .init(node: .init(id: "client:doomed", text: "Doomed")))).variable) }
        await until { gate.pending != 0 }
        #expect(character.notes.nodes.count == 6)
        gate.fail(TransportError(statusCode: 500, body: "no"))
        await #expect(throws: TransportError.self) { try await failing.value }
        #expect(character.notes.nodes.count == 5)
        withExtendedLifetime(retention) {}
    }

    @Test("@deleteEdge removes the node's edge and @deleteRecord makes the record read as null")
    func deleteDirectives() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        let second = try #require(character.notes.nodes.last)
        #expect(second.text == "Portal gun needs charging")
        let (fired, track) = counter { _ = second.text }

        track()
        let removal = TestRemoveNote(id: "n2", connections: [character.notes.connectionID])
        let payload = fixture("remove-note-n2")
        environment.store.commit(try Ingest.normalize(payload, plan: TestRemoveNote.plan.resolve(removal.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub"])
        #expect(fired() == 1, "the deleted record's observer was told")
        let record = try #require(environment.store.existing("Note:n2"))
        #expect(record.deleted)
        #expect(second.text == nil)

        // The edges list lost the edge, not only the node behind it.
        #expect(character.notes.edges?.count == 1)
        withExtendedLifetime(retention) {}
    }

    @Test("loadPrevious fetches before the start cursor, prepends, and is a no-op at the start")
    func loadPrevious() async throws {
        let transport = RecordedTransport { request in
            if request.operationName == TestRecentNotesQuery.name { return fixture("recent-notes-page-1") }
            switch request.variables["cursor"] {
            case .string("c4")?: return fixture("recent-notes-page-2")
            case .string("c2")?: return fixture("recent-notes-page-3")
            default: return nil
            }
        }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestRecentNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the last page did not arrive") }
        let notes = try #require(data.character?.testRecentNotes.notes)
        #expect(notes.nodes.map(\.id) == ["n4", "n5"])
        #expect(notes.hasPrevious)

        try await notes.loadPrevious()
        #expect(transport.requests.last?.operationName == "TestRecentNotesPaginationQuery")
        #expect(transport.requests.last?.variables["cursor"] == .string("c4"))
        #expect(transport.requests.last?.variables["count"] == .int(2))
        #expect(transport.requests.last?.variables["id"] == .string("1"))
        #expect(notes.nodes.map(\.id) == ["n2", "n3", "n4", "n5"], "the earlier page goes in front")
        #expect(!notes.isLoadingPrevious)

        try await notes.loadPrevious(1)
        #expect(transport.requests.last?.variables["count"] == .int(1))
        #expect(notes.nodes.map(\.id) == ["n1", "n2", "n3", "n4", "n5"])
        #expect(!notes.hasPrevious)

        try await notes.loadPrevious()
        #expect(transport.requestCount == 3, "nothing before the start")
        withExtendedLifetime(retention) {}
    }

    @Test("@appendNode and @prependNode wrap the payload's node in an edge of the connection named by the variable")
    func nodeDirectives() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        let connections = [character.notes.connectionID]
        let (fired, track) = counter { _ = character.notes.nodes }

        track()
        let appended = TestAddNoteNode(characterId: "1", text: "Node appended", connections: connections)
        environment.store.commit(try Ingest.normalize(fixture("add-note-node-n7"), plan: TestAddNoteNode.plan.resolve(appended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Node appended"])
        #expect(fired() == 1)
        #expect(character.notes.edges?.last?.cursor == "", "the edge the store made has no cursor")

        let prepended = TestAddNoteNodeFirst(characterId: "1", text: "Node first", connections: connections)
        environment.store.commit(try Ingest.normalize(fixture("add-note-node-n0"), plan: TestAddNoteNodeFirst.plan.resolve(prepended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Node first", "Wubba lubba dub dub", "Portal gun needs charging", "Node appended"])

        // The same node again is not wrapped twice.
        environment.store.commit(try Ingest.normalize(fixture("add-note-node-n7"), plan: TestAddNoteNode.plan.resolve(appended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.count == 4)
        withExtendedLifetime(retention) {}
    }

    @Test("an edge directive that names a record no connection field made leaves the record alone")
    func edgeDirectiveOnARecordThatIsNotAConnection() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        let entity = try #require(environment.store.existing("Character:1"))
        let appended = TestAddNote(characterId: "1", text: "Appended", connections: ["Character:1"])
        environment.store.commit(try Ingest.normalize(fixture("add-note-n9"), plan: TestAddNote.plan.resolve(appended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(environment.store.existing("Character:1:edges:0") == nil, "no edge was made for it")
        #expect(entity.read(Registry.slot(entity.type, "edges")) == .missing)
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])
        withExtendedLifetime(retention) {}
    }

    @Test("@appendNode whose edge type is not the connection's inserts no edge")
    func nodeDirectiveOfAnotherEdgeType() async throws {
        let (environment, character, retention) = try await seededEnvironment()
        let appended = TestAddNoteNodeOfAnotherType(characterId: "1", text: "Node appended", connections: [character.notes.connectionID])
        environment.store.commit(try Ingest.normalize(fixture("add-note-node-n7"), plan: TestAddNoteNodeOfAnotherType.plan.resolve(appended.variables, in: environment.store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.edges?.count == 2)
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])
        withExtendedLifetime(retention) {}
    }

    @Test("refetch fetches the fragment again with its variables and the owner's id, and the records update in place")
    func refetch() async throws {
        let transport = RecordedTransport { request in
            request.operationName == TestNotesQuery.name ? notesPage(1) : fixture("notes-refetch")
        }
        let (environment, character, retention) = try await seededEnvironment(transport)
        let first = try #require(character.notes.nodes.first)
        #expect(first.text == "Wubba lubba dub dub")
        let (fired, track) = counter { _ = first.text }
        track()

        try await character.refetch()
        let request = try #require(transport.requests.last)
        #expect(request.operationName == "TestNotesPaginationQuery")
        #expect(request.variables["id"] == .string("1"))
        #expect(request.variables["count"] == .int(2))
        #expect(first.text == "Wubba lubba dub dub!", "the lens over the same record reads the new value")
        #expect(fired() == 1)
        #expect(character.notes.nodes.count == 2)
        #expect(environment.store.rootCount == 2, "the notes query's root and the refetch query's, dated and waiting in the buffer")
        withExtendedLifetime(retention) {}
    }

    @Test("fields named like a refetchable fragment and its refetch query, in its lens and in its connection's, leave refetch and loadNext fetching through the query")
    func refetchAndLoadNextPastFieldsNamedLikeThem() async throws {
        let transport = RecordedTransport { request in
            if request.operationName == TestHiddenNotesQuery.name { return fixture("hidden-notes-page-1") }
            return request.variables["cursor"] == .string("c2") ? fixture("hidden-notes-page-2") : fixture("hidden-notes-refetch")
        }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestHiddenNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the first page did not arrive") }
        let character = try #require(data.character?.testHiddenNotes)
        #expect(character.TestHiddenNotes_character == "Rick Sanchez")
        #expect(character.TestHiddenNotesPaginationQuery == "Alive")
        #expect(character.notes.TestHiddenNotes_character == 5)
        #expect(character.notes.TestHiddenNotesPaginationQuery == 5)
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])

        try await character.notes.loadNext()
        #expect(transport.requests.last?.operationName == "TestHiddenNotesPaginationQuery")
        #expect(transport.requests.last?.variables["cursor"] == .string("c2"))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel"])

        try await character.refetch()
        let request = try #require(transport.requests.last)
        #expect(request.operationName == "TestHiddenNotesPaginationQuery")
        #expect(request.variables["id"] == .string("1"))
        #expect(request.variables["count"] == .int(2))
        #expect(character.notes.nodes.first?.text == "Wubba lubba dub dub!")
        #expect(transport.requestCount == 3)
        withExtendedLifetime(retention) {}
    }

    @Test("fields named like a refetchable fragment and its refetch query in its connection's lens leave loadPrevious fetching through the query")
    func loadPreviousPastFieldsNamedLikeThem() async throws {
        let transport = RecordedTransport { request in
            request.operationName == TestHiddenRecentNotesQuery.name ? fixture("hidden-recent-notes-page-1") : fixture("hidden-recent-notes-page-2")
        }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestHiddenRecentNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the last page did not arrive") }
        let notes = try #require(data.character?.testHiddenRecentNotes.notes)
        #expect(notes.TestHiddenRecentNotes_character == 5)
        #expect(notes.nodes.map(\.id) == ["n4", "n5"])

        try await notes.loadPrevious()
        #expect(transport.requests.last?.operationName == "TestHiddenRecentNotesPaginationQuery")
        #expect(transport.requests.last?.variables["cursor"] == .string("c4"))
        #expect(notes.nodes.map(\.id) == ["n2", "n3", "n4", "n5"])
        withExtendedLifetime(retention) {}
    }

    @Test("a spread with @arguments binds the fragment's variables once, so each read of it is the same lens; a spread without them takes the defaults")
    func fragmentArguments() async throws {
        let store = Store()
        store.reportMissing = nil
        let sized = TestNotesSizedQuery(id: "1", size: 7)
        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesSizedQuery.plan.resolve(sized.variables, in: store.keys)))
        let data = TestNotesSizedQuery.Data(anchor: Anchor(record: store.root, variables: sized.variables, store: store))
        let character = try #require(data.character?.testNotes)
        #expect(character.anchor.variables["count"] == .int(7))
        #expect(character.anchor.variables["cursor"] == .null)
        #expect(character.notes.nodes.count == 2)
        #expect(data.character?.testNotes.anchor == character.anchor, "the owner bound the spread once")

        let plain = TestNotesQuery.Data(anchor: Anchor(record: store.root, variables: TestNotesQuery(id: "1").variables, store: store))
        #expect(plain.character?.testNotes.anchor.variables["count"] == .int(2), "the @argumentDefinitions default")
        #expect(store.existing("Character:1:notes(first:7)") != nil, "the page is stored under the inlined arguments")
    }

    @Test("the first page fetched by a query with no cursor and the same page fetched by the refetch query given no cursor land on one record, keyed without the null cursor")
    func theFirstPageWithAndWithoutANullCursorIsOneRecord() throws {
        let store = Store()
        store.reportMissing = nil
        let screen = TestNotesQuery(id: "1")
        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(screen.variables, in: store.keys)))
        let refetch = TestNotesPaginationQuery(count: 2, cursor: nil, id: "1")
        store.commit(try Ingest.normalize(fixture("notes-refetch"), plan: TestNotesPaginationQuery.plan.resolve(refetch.variables, in: store.keys)))

        let pages = store.recordsByKey.keys.filter { $0.hasPrefix("Character:1:notes(") && $0.hasSuffix(")") }
        #expect(pages == ["Character:1:notes(first:2)"], "one page record, with no null argument in its key")
        let page = try #require(store.existing("Character:1:notes(first:2)"))
        guard case .refs(let edges) = page.read(Registry.slot(page.type, "edges")) else {
            Issue.record("the page holds its edges")
            return
        }
        #expect(edges.map { $0?.key } == ["Character:1:notes(first:2):edges:0", "Character:1:notes(first:2):edges:1"])
        let character = try #require(store.existing("Character:1"))
        let edge = try #require(edges.first ?? nil)
        guard case .ref(let note) = edge.read(Registry.slot(edge.type, "node")) else {
            Issue.record("the edge links its note")
            return
        }
        #expect(note.read(Registry.slot(note.type, "text")) == .string("Wubba lubba dub dub!"), "the refetch wrote over the screen's page")
        #expect(character.storedSlots.contains { store.storageKey(of: $0.0) == "notes(first:2)" })
    }

    @Test("a query whose page was fetched after a cursor is whole once its response is in, and a field error inside the page lands on the field it names")
    func pageAfterACursor() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: store.keys)))
        let plan = TestNotesPaginationQuery.plan.resolve(TestNotesPaginationQuery(count: 2, cursor: "c2", id: "1").variables, in: store.keys)
        #expect(store.check(plan) == .miss, "the first page does not answer the second")
        let changes = try Ingest.normalize(fixture("notes-page-2-errors"), plan: plan)
        let placed = try #require(changes.fieldErrors.first)
        #expect(changes.recordKeys[Int(placed.record)] == "Note:n3")
        #expect(store.storageKey(of: placed.slot) == "text")
        store.commit(changes)
        #expect(store.check(plan) == .memory)
        #expect(store.existing("Note:n3")?.error(Registry.slot(Registry.type("Note"), "text"))?.message == "text hidden")
    }

    @Test("a deferred part under a page fetched after a cursor lands on the page's node, and a failed one leaves its error there")
    func deferredUnderAppendedPage() async throws {
        let environment = Environment(transport: Parts([fixture("deferred-notes-page-2-1"), fixture("deferred-notes-page-2-2")]))
        environment.store.reportMissing = nil
        _ = try await environment.fetch(TestDeferredNotesPaginationQuery.self, variables: TestDeferredNotesPaginationQuery(count: 2, cursor: "c2", id: "1").variables)
        let text = Registry.slot(Registry.type("Note"), "text")
        #expect(environment.store.existing("Note:n3")?.read(text) == .string("Get Schwifty"))
        #expect(environment.store.existing("Note:n4")?.error(text)?.message == "text hidden")
    }

    @Test("an error inside the second page a response merges into one connection lands on that page's record")
    func errorInTheSecondPage() throws {
        let store = Store()
        let changes = try Ingest.normalize(fixture("two-notes-pages"), plan: TestTwoPagesQuery.plan.resolve(TestTwoPagesQuery(id: "1").variables, in: store.keys))
        store.reportMissing = nil
        store.commit(changes)
        let text = Registry.slot(Registry.type("Note"), "text")
        #expect(store.existing("Note:n3")?.error(text)?.message == "text hidden")
        #expect(store.existing("Note:n1")?.error(text) == nil)
    }

    @Test("@alias(as:) names the spread's accessor")
    func aliasRenames() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let query = TestAliasQuery(id: "1")
        #expect(store.check(TestAliasQuery.plan.resolve(query.variables, in: store.keys)) != .miss, "the lookup finds the character the list fetched")
        let data = TestAliasQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.character?.row.name == "Rick Sanchez")
    }

    @Test("pages appended to a connection by loadNext drop no link and run no collection pass")
    func appendedPagesRunNoCollection() async throws {
        // A buffer large enough that no page's root pushes another out, so
        // only the commits themselves could schedule a pass.
        let store = Store(releaseBufferSize: 100)
        let (environment, character, retention) = try await seededEnvironment(store: store)
        await turns()
        let collections = store.collections

        try await character.notes.loadNext()
        await turns()
        #expect(character.notes.nodes.count == 4)
        #expect(store.collections == collections, "the second page only grew the list")

        try await character.notes.loadNext(10)
        await turns()
        #expect(character.notes.nodes.count == 5)
        #expect(store.collections == collections, "the third page only grew the list")
        withExtendedLifetime((environment, retention)) {}
    }

    @Test("a refetch of the first page that replaces the merged list schedules one collection pass on the next turn")
    func replacedListRunsOneCollection() async throws {
        let store = Store(releaseBufferSize: 100)
        let (environment, character, retention) = try await seededEnvironment(store: store)
        try await character.notes.loadNext()
        await turns()
        let collections = store.collections

        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: store.keys)))
        #expect(character.notes.nodes.count == 2, "the first page again replaces the merged list")
        #expect(store.collections == collections, "the pass waits for the next turn")
        await until { store.collections > collections }
        await turns()
        #expect(store.collections == collections + 1, "one pass for the commit")
        #expect(store.existing("Note:n3") != nil, "the second page's root, waiting in the buffer, still reaches the notes the list dropped")
        withExtendedLifetime((environment, retention)) {}
    }

    @Test("a @deleteEdge mutation that removes an edge from a connection schedules a collection pass")
    func removedEdgeRunsCollection() async throws {
        let store = Store(releaseBufferSize: 100)
        let (environment, character, retention) = try await seededEnvironment(store: store)
        await turns()
        let collections = store.collections

        let removal = TestRemoveNote(id: "n2", connections: [character.notes.connectionID])
        store.commit(try Ingest.normalize(fixture("remove-note-n2"), plan: TestRemoveNote.plan.resolve(removal.variables, in: store.keys), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub"])
        await until { store.collections > collections }
        await turns()
        #expect(store.collections == collections + 1, "one pass for the commit")
        withExtendedLifetime((environment, retention)) {}
    }
}
