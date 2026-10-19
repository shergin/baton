@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

/// A recorded page of the notes paged by number.
func pagedNotes(_ name: String) -> Data {
    fixture("paged-notes-\(name)")
}

/// A transport that answers each run of the paged notes query with the page
/// its `page` variable names, the friends query likewise, and the paged
/// characters with their one page.
func pagedTransport() -> RecordedTransport {
    RecordedTransport { request in
        let page: Int? = if case .int(let page)? = request.variables["page"] { page } else { nil }
        switch (request.operationName, page) {
        case (TestPagedNotesQuery.name, 1?): return pagedNotes("1")
        case (TestPagedNotesQuery.name, 2?): return pagedNotes("2")
        case (TestPagedNotesQuery.name, 3?): return pagedNotes("3")
        case (TestPagedCharactersQuery.name, 1?): return fixture("paged-characters-1")
        case (TestFriendsQuery.name, 1?): return fixture("friends-1")
        case (TestFriendsQuery.name, 2?): return fixture("friends-2")
        default: return nil
        }
    }
}

/// A list paged by number under `@paged`, through the environment over the
/// operations of `PagedDocuments`: what `loadNext()` sends and merges, the
/// loading flag, a refetch, a lens made by hand, and two lists under one
/// server page. The script `paged` holds the merge rules page by page.
@MainActor
@Suite("Paged lists", .timeLimit(.minutes(1)))
struct PagedTests {
    /// The paged notes' first page, fetched and held as a view on screen
    /// holds it, and the lens over its container.
    func notes(in environment: Environment) async throws -> (OperationHandle<TestPagedNotesQuery>, TestPagedNotesQuery.Data.Page, Retention) {
        let handle = environment.handle(for: TestPagedNotesQuery(page: 1, authorId: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase, let page = data.page else {
            throw TransportError(statusCode: 0, body: "the first page did not arrive")
        }
        return (handle, page, retention)
    }

    func environment(_ transport: any Transport) -> Environment {
        let environment = Environment(transport: transport)
        environment.log = nil
        return environment
    }

    @Test("loadNext sends the owning query with the next page and the owner's other variables, appends the page, and sends nothing once hasNext is false")
    func loadNextAppendsUntilTheEnd() async throws {
        let transport = pagedTransport()
        let environment = environment(transport)
        let (_, page, retention) = try await notes(in: environment)
        #expect(page.notes?.map(\.id) == ["n1", "n2"])
        #expect(page.hasNext)
        #expect(transport.requestCount == 1)

        try await page.loadNext()
        #expect(transport.requestCount == 2)
        let request = transport.requests[1]
        #expect(request.operationName == TestPagedNotesQuery.name)
        #expect(request.variables == Variables(["page": .int(2), "authorId": .string("1")]))
        #expect(
            String(decoding: request.body, as: UTF8.self)
                == #"{"operationName":"TestPagedNotesQuery","query":"query TestPagedNotesQuery($page:Int!,$authorId:ID!){page(page:$page,perPage:2){pageInfo{hasNextPage,currentPage},notes(authorId:$authorId){id,text}}}","variables":{"authorId":"1","page":2}}"#
        )
        #expect(page.notes?.map(\.id) == ["n1", "n2", "n3", "n4"])
        #expect(page.pageInfo.currentPage == 2)
        #expect(page.hasNext)
        #expect(!page.isLoadingNext)

        try await page.loadNext()
        #expect(transport.requests[2].variables == Variables(["page": .int(3), "authorId": .string("1")]))
        #expect(page.notes?.map(\.id) == ["n1", "n2", "n3", "n4", "n5"])
        #expect(!page.hasNext)

        try await page.loadNext()
        #expect(transport.requestCount == 3, "nothing to load")

        // Each page fetched is dated on a root of its own, which nothing
        // retains and so waits in the release buffer; the merged record
        // keeps its pages through the notes query's root.
        #expect(environment.store.rootCount == 3, "the notes query's root and the two pages' waiting in the buffer")
        environment.store.collect()
        #expect(page.notes?.map(\.id) == ["n1", "n2", "n3", "n4", "n5"])
        #expect(environment.store.existing("Note:n5") != nil)
        withExtendedLifetime(retention) {}
    }

    @Test("isLoadingNext reads true on the lens while the next page is in flight, and a second loadNext meanwhile sends nothing")
    func theLoadingFlagCoversTheFetch() async throws {
        let transport = ScriptedTransport { request in
            request.variables["page"] == .int(1) ? pagedNotes("1") : nil
        }
        transport.hold(TestPagedNotesQuery.name)
        let environment = environment(transport)
        let (_, page, retention) = try await notes(in: environment)
        #expect(!page.isLoadingNext)

        let loading = Task { try await page.loadNext() }
        await until { !transport.held.isEmpty }
        #expect(page.isLoadingNext)
        try await page.loadNext()
        #expect(transport.requestCount == 2, "a page in flight is not asked for again")

        try #require(transport.held.first).respond(pagedNotes("2"))
        try await loading.value
        #expect(!page.isLoadingNext)
        #expect(page.notes?.map(\.id) == ["n1", "n2", "n3", "n4"])
        withExtendedLifetime(retention) {}
    }

    @Test("loadNext through a fragment's lens on an entity sends the query that spreads the fragment, with the entity's id and the next page")
    func aFragmentsListPagesThroughItsOperation() async throws {
        let transport = pagedTransport()
        let environment = environment(transport)
        let handle = environment.handle(for: TestFriendsQuery(id: "1", page: 1))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase, let friends = data.character?.testFriends.friends else {
            throw TransportError(statusCode: 0, body: "the first page did not arrive")
        }
        #expect(friends.nodes?.map(\.name) == ["Morty Smith", "Summer Smith"])
        #expect(friends.hasNext)

        try await friends.loadNext()
        let request = try #require(transport.requests.last)
        #expect(request.operationName == TestFriendsQuery.name)
        #expect(request.variables == Variables(["id": .string("1"), "page": .int(2)]))
        #expect(friends.nodes?.map(\.name) == ["Morty Smith", "Summer Smith", "Beth Smith", "Jerry Smith"])
        #expect(!friends.hasNext)
        #expect(environment.store.existing("Character:1:__TestFriends_nodes_paged(perPage:2)") != nil, "the merged record hangs off the character")
        withExtendedLifetime(retention) {}
    }

    @Test("a lens made by hand has no operation to page through, and loadNext throws when there is a page to load")
    func aLensMadeByHandThrows() async throws {
        let store = Store()
        store.log = nil
        let operation = TestPagedNotesQuery(page: 1, authorId: "1")
        store.commit(try Ingest.normalize(pagedNotes("1"), plan: TestPagedNotesQuery.plan.resolve(operation.variables, in: store.keys)))
        let data = TestPagedNotesQuery.Data(anchor: Anchor(record: store.root, variables: operation.variables, store: store))
        let page = try #require(data.page)
        #expect(page.notes?.map(\.id) == ["n1", "n2"])
        #expect(page.hasNext)
        await #expect(throws: EnvironmentError.outsideEnvironment) { try await page.loadNext() }
        #expect(!page.isLoadingNext)
    }

    @Test("a refetch of the owning handle after two pages fetches the first page again and replaces the merged list with it")
    func aRefetchReplacesTheList() async throws {
        let transport = pagedTransport()
        let environment = environment(transport)
        let (handle, page, retention) = try await notes(in: environment)
        try await page.loadNext()
        #expect(page.notes?.map(\.id) == ["n1", "n2", "n3", "n4"])
        #expect(page.pageInfo.currentPage == 2)

        try await handle.refetch()
        #expect(transport.requests.last?.variables == Variables(["page": .int(1), "authorId": .string("1")]))
        #expect(page.notes?.map(\.id) == ["n1", "n2"])
        #expect(page.pageInfo.currentPage == 1)
        #expect(page.hasNext)

        // The list starts again from its first page, so the next one is 2.
        try await page.loadNext()
        #expect(transport.requests.last?.variables == Variables(["page": .int(2), "authorId": .string("1")]))
        #expect(page.notes?.map(\.id) == ["n1", "n2", "n3", "n4"])
        withExtendedLifetime(retention) {}
    }

    @Test("two lists paged under one server page keep their own hasNext, though the page's one page info reads the last list's")
    func twoListsUnderOnePageKeepTheirOwnPageInfo() async throws {
        let transport = pagedTransport()
        let environment = environment(transport)
        let (_, notes, notesRetention) = try await notes(in: environment)
        let charactersHandle = environment.handle(for: TestPagedCharactersQuery(page: 1))
        let charactersRetention = charactersHandle.retain()
        await charactersHandle.settle()
        guard case .ready(let data) = charactersHandle.phase, let characters = data.page else {
            throw TransportError(statusCode: 0, body: "the characters did not arrive")
        }
        #expect(characters.characters?.map(\.name) == ["Rick Sanchez", "Morty Smith"])

        // One server record holds both lists' first pages and one page info,
        // which says what the characters' page said.
        let shared = try #require(environment.store.existing("client:root:page(page:1,perPage:2):pageInfo"))
        #expect(shared.read(Registry.slot(shared.type, "hasNextPage")) == .bool(false))
        #expect(notes.hasNext)
        #expect(notes.pageInfo.hasNextPage)
        #expect(!characters.hasNext)

        try await characters.loadNext()
        #expect(transport.requestCount == 2, "the characters have no next page")
        try await notes.loadNext()
        #expect(transport.requests.last?.operationName == TestPagedNotesQuery.name)
        #expect(notes.notes?.map(\.id) == ["n1", "n2", "n3", "n4"])
        #expect(characters.characters?.map(\.name) == ["Rick Sanchez", "Morty Smith"])
        withExtendedLifetime((notesRetention, charactersRetention)) {}
    }
}
