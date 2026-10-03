import Baton
import Foundation
import Observation
import Testing

@MainActor
@Suite("Lists")
struct ListTests {
    /// Answers the notes query with page 1 and the pagination query with the
    /// page after the cursor it carries; counts the requests.
    final class PagingTransport: Transport, @unchecked Sendable {
        var requests: [Request] = []
        var fail = false

        func execute(_ request: Request) async throws -> Data {
            requests.append(request)
            if fail { throw TransportError(statusCode: 500, body: "no") }
            if request.operationName == TestNotesQuery.name { return notesPage(1) }
            switch request.variables["cursor"] {
            case .string("c2")?: return notesPage(2)
            case .string("c4")?: return notesPage(3)
            default: return notesPage(1)
            }
        }
    }

    func seededEnvironment(_ transport: any Transport = PagingTransport()) async throws -> (Environment, TestNotes_character) {
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the first page did not arrive") }
        return (environment, try #require(data.character?.testNotes))
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
        let (environment, character) = try await seededEnvironment()
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])
        #expect(character.notes.totalCount == 5)
        #expect(character.notes.hasNext)
        #expect(character.notes.connectionID == "Character:1:__TestNotes_notes_connection")

        // The second page, as the pagination query delivers it.
        let variables = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c2")])
        environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables)))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel"])
        #expect(character.notes.hasNext)
        #expect(character.notes.pageInfo.endCursor == "c4")

        // The same page again changes nothing; a page after a stale cursor is ignored.
        let unchanged = environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables)))
        #expect(unchanged == 0)
        let stale = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c1")])
        environment.store.commit(try Ingest.normalize(notesPage(3), plan: TestNotesPaginationQuery.plan.resolve(stale)))
        #expect(character.notes.nodes.count == 4)
    }

    @Test("refetching the first page replaces the merged list, and an equal page notifies nothing")
    func refetchReplaces() async throws {
        let (environment, character) = try await seededEnvironment()
        let (fired, track) = counter { _ = character.notes.nodes }
        let variables = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c2")])
        track()
        environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables)))
        #expect(fired() == 1, "the list grew")
        #expect(character.notes.nodes.count == 4)

        track()
        environment.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables)))
        #expect(character.notes.nodes.count == 2, "a refetch without a cursor is the first page again")
        #expect(character.notes.pageInfo.endCursor == "c2")
        #expect(fired() == 2)

        track()
        environment.store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables)))
        #expect(fired() == 2, "the same first page again: same edges, no notification")
    }

    @Test("loadNext fetches after the end cursor, appends, and is a no-op at the end")
    func loadNext() async throws {
        let transport = PagingTransport()
        let (environment, character) = try await seededEnvironment(transport)
        #expect(transport.requests.count == 1)

        try await character.notes.loadNext()
        #expect(transport.requests.count == 2)
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
        #expect(transport.requests.count == 3, "nothing to load")

        // The pagination fetches created no roots; the connection keeps its pages.
        #expect(environment.rootCount == 1)
        environment.collect()
        #expect(character.notes.nodes.count == 5)
        #expect(environment.store.existing("Note:n5") != nil)
    }

    @Test("isLoadingNext is a client field on the connection record while the page is in flight")
    func loadingFlag() async throws {
        let (environment, character) = try await seededEnvironment()
        let gate = GatedTransport()
        // A second environment over the same store takes the lens's fetches.
        let paging = Environment(transport: gate, store: environment.store)
        #expect(!character.notes.isLoadingNext)
        let loading = Task { try await character.notes.loadNext() }
        while gate.pending == 0 { await Task.yield() }
        #expect(character.notes.isLoadingNext)
        gate.respond(notesPage(2))
        try await loading.value
        #expect(!character.notes.isLoadingNext)
        #expect(character.notes.nodes.count == 4)
        #expect(paging.rootCount == 0, "a page fetch is no root")
    }

    @Test("@appendEdge and @prependEdge insert the payload's edge into the connection named by the variable")
    func edgeDirectives() async throws {
        let (environment, character) = try await seededEnvironment()
        let connections = [character.notes.connectionID]
        let (fired, track) = counter { _ = character.notes.nodes }

        track()
        let appended = TestAddNote(characterId: "1", text: "Appended", connections: connections)
        let payload = fixture("add-note-n9")
        environment.store.commit(try Ingest.normalize(payload, plan: TestAddNote.plan.resolve(appended.variables), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Appended"])
        #expect(fired() == 1)

        let prepended = TestAddNoteFirst(characterId: "1", text: "First", connections: connections)
        let first = fixture("add-note-n0")
        environment.store.commit(try Ingest.normalize(first, plan: TestAddNoteFirst.plan.resolve(prepended.variables), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["First", "Wubba lubba dub dub", "Portal gun needs charging", "Appended"])

        // The same node again is not inserted twice.
        environment.store.commit(try Ingest.normalize(payload, plan: TestAddNote.plan.resolve(appended.variables), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.count == 4)
    }

    @Test("an optimistic @appendEdge shows at once, survives a page under it, and is replaced by the server's edge")
    func optimisticEdge() async throws {
        let gate = GatedTransport()
        let (environment, character) = try await seededEnvironment()
        let mutating = Environment(transport: gate, store: environment.store)
        let connections = [character.notes.connectionID]
        let optimistic = TestAddNote.OptimisticResponse(addNote: .init(noteEdge: .init(node: .init(id: "client:new", text: "Pending"))))

        let mutation = Task { try await mutating.mutate(TestAddNote(characterId: "1", text: "Pending", connections: connections), optimistic: optimistic.variable) }
        while gate.pending == 0 { await Task.yield() }
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Pending"])

        // A page arrives while the layer is live: it lands under the optimistic edge.
        let variables = Variables(["id": .string("1"), "count": .int(2), "cursor": .string("c2")])
        environment.store.commit(try Ingest.normalize(notesPage(2), plan: TestNotesPaginationQuery.plan.resolve(variables)))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel", "Pending"])

        gate.respond(fixture("add-note-n9-pending"))
        _ = try await mutation.value
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging", "Get Schwifty", "Avoid the Citadel", "Pending"])
        #expect(character.notes.nodes.last?.id == "n9")
        #expect(environment.store.optimisticLayers.isEmpty)

        // A failure reverts the optimistic edge.
        let failing = Task { try await mutating.mutate(TestAddNote(characterId: "1", text: "Doomed", connections: connections), optimistic: TestAddNote.OptimisticResponse(addNote: .init(noteEdge: .init(node: .init(id: "client:doomed", text: "Doomed")))).variable) }
        while gate.pending == 0 { await Task.yield() }
        #expect(character.notes.nodes.count == 6)
        gate.fail(TransportError(statusCode: 500, body: "no"))
        await #expect(throws: TransportError.self) { try await failing.value }
        #expect(character.notes.nodes.count == 5)
    }

    @Test("@deleteEdge removes the node's edge and @deleteRecord makes the record read as null")
    func deleteDirectives() async throws {
        let (environment, character) = try await seededEnvironment()
        let second = try #require(character.notes.nodes.last)
        #expect(second.text == "Portal gun needs charging")
        let (fired, track) = counter { _ = second.text }

        track()
        let removal = TestRemoveNote(id: "n2", connections: [character.notes.connectionID])
        let payload = fixture("remove-note-n2")
        environment.store.commit(try Ingest.normalize(payload, plan: TestRemoveNote.plan.resolve(removal.variables), rootKey: Store.mutationRootKey))
        #expect(character.notes.nodes.map(\.text) == ["Wubba lubba dub dub"])
        #expect(fired() == 1, "the deleted record's observer was told")
        let record = try #require(environment.store.existing("Note:n2"))
        #expect(record.deleted)
        #expect(second.text == nil)

        // The edges list lost the edge, not only the node behind it.
        #expect(character.notes.edges?.count == 1)
    }

    @Test("a spread with @arguments binds the fragment's variables; a spread without them takes the defaults")
    func fragmentArguments() async throws {
        let store = Store()
        store.reportMissing = nil
        let sized = TestNotesSizedQuery(id: "1", size: 7)
        store.commit(try Ingest.normalize(notesPage(1), plan: TestNotesSizedQuery.plan.resolve(sized.variables)))
        let data = TestNotesSizedQuery.Data(anchor: Anchor(record: store.root, variables: sized.variables, store: store))
        let character = try #require(data.character?.testNotes)
        #expect(character.anchor.variables["count"] == .int(7))
        #expect(character.anchor.variables["cursor"] == .null)
        #expect(character.notes.nodes.count == 2)

        let plain = TestNotesQuery.Data(anchor: Anchor(record: store.root, variables: TestNotesQuery(id: "1").variables, store: store))
        #expect(plain.character?.testNotes.anchor.variables["count"] == .int(2), "the @argumentDefinitions default")
        #expect(store.existing("Character:1:notes(after:null,first:7)") != nil, "the page is stored under the inlined arguments")
    }

    @Test("@alias(as:) names the spread's accessor")
    func aliasRenames() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let query = TestAliasQuery(id: "1")
        let data = TestAliasQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store))
        #expect(data.character?.row.name == "Rick Sanchez")
    }
}
