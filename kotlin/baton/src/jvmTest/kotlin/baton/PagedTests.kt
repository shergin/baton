package baton

import baton.spec.TestFriendsQuery
import baton.spec.TestPagedCharactersQuery
import baton.spec.TestPagedNotesQuery
import baton.spec.Types
import baton.testing.RecordedTransport
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * A list paged by number under `@paged`, through the environment over the
 * operations generated from `spec/sources`: what `loadNext()` sends and
 * merges, the loading flag, a refetch, a lens made by hand, and two lists
 * under one server page. Mirrors `swift/Tests/BatonTests/PagedTests.swift`;
 * the script `paged` holds the merge rules page by page.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PagedTests {
    private fun pagedNotes(name: String): ByteArray = Spec.bytes("tests/paged-notes-$name.json")

    /** Answers each run of the paged notes query with the page its `page` variable names, the friends query likewise, and the paged characters with their one page. */
    private fun pagedTransport(): RecordedTransport = RecordedTransport { request ->
        val page = (request.variables["page"] as? Variable.Int)?.value
        when (request.operationName to page) {
            "TestPagedNotesQuery" to 1L -> pagedNotes("1")
            "TestPagedNotesQuery" to 2L -> pagedNotes("2")
            "TestPagedNotesQuery" to 3L -> pagedNotes("3")
            "TestPagedCharactersQuery" to 1L -> Spec.bytes("tests/paged-characters-1.json")
            "TestFriendsQuery" to 1L -> Spec.bytes("tests/friends-1.json")
            "TestFriendsQuery" to 2L -> Spec.bytes("tests/friends-2.json")
            else -> null
        }
    }

    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher. */
    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher)
    }

    /** The paged notes' first page, fetched and held as a screen holds it, and the lens over its container. */
    private fun TestScope.notes(environment: Environment): Triple<OperationHandle<TestPagedNotesQuery.Data>, TestPagedNotesQuery.Data.Page, Hold> {
        val handle = environment.handle(TestPagedNotesQuery(page = 1, authorId = "1"))
        val hold = handle.retain()
        runCurrent()
        val data = assertIs<Phase.Ready<TestPagedNotesQuery.Data>>(handle.phase).data
        return Triple(handle, assertNotNull(data.page), hold)
    }

    @Test
    fun `loadNext sends the owning query with the next page and the owner's other variables, appends the page, and sends nothing once hasNext is false`() = runTest {
        val transport = pagedTransport()
        val environment = environment(transport)
        val (_, page, hold) = notes(environment)
        assertEquals(listOf("n1", "n2"), page.notes?.map { it.id })
        assertTrue(page.hasNext)
        assertEquals(1, transport.requestCount)

        page.loadNext()
        assertEquals(2, transport.requestCount)
        val request = transport.requests[1]
        assertEquals("TestPagedNotesQuery", request.operationName)
        assertEquals(mapOf("page" to Variable.Int(2), "authorId" to Variable.String("1")), request.variables.values)
        assertEquals(
            """{"operationName":"TestPagedNotesQuery","query":"query TestPagedNotesQuery(${'$'}page:Int!,${'$'}authorId:ID!){page(page:${'$'}page,perPage:2){pageInfo{hasNextPage,currentPage},notes(authorId:${'$'}authorId){id,text}}}","variables":{"authorId":"1","page":2}}""",
            request.body.decodeToString(),
        )
        assertEquals(listOf("n1", "n2", "n3", "n4"), page.notes?.map { it.id })
        assertEquals(2, page.pageInfo.currentPage)
        assertTrue(page.hasNext)
        assertFalse(page.isLoadingNext)

        page.loadNext()
        assertEquals(mapOf("page" to Variable.Int(3), "authorId" to Variable.String("1")), transport.requests[2].variables.values)
        assertEquals(listOf("n1", "n2", "n3", "n4", "n5"), page.notes?.map { it.id })
        assertFalse(page.hasNext)

        page.loadNext()
        assertEquals(3, transport.requestCount, "nothing to load")

        // Each page is dated on a root of its own, which waits in the release buffer; the merged record keeps its pages
        // through the notes query's root.
        assertEquals(3, environment.store.rootCount, "the notes query's root and the two pages' waiting in the buffer")
        environment.store.collect()
        assertEquals(listOf("n1", "n2", "n3", "n4", "n5"), page.notes?.map { it.id })
        assertNotNull(environment.store.existing("Note:n5"))
        hold.release()
        environment.end()
    }

    @Test
    fun `isLoadingNext reads true on the lens while the next page is in flight, and a second loadNext meanwhile sends nothing`() = runTest {
        val transport = ScriptedTransport(responder = { request -> if (request.variables["page"] == Variable.Int(1)) pagedNotes("1") else null })
        transport.hold("TestPagedNotesQuery")
        val environment = environment(transport)
        val (_, page, hold) = notes(environment)
        assertFalse(page.isLoadingNext)

        val loading = async { page.loadNext() }
        runCurrent()
        assertTrue(page.isLoadingNext)
        page.loadNext()
        assertEquals(2, transport.requestCount, "a page in flight is not asked for again")

        transport.held.single().respond(pagedNotes("2"))
        loading.await()
        assertFalse(page.isLoadingNext)
        assertEquals(listOf("n1", "n2", "n3", "n4"), page.notes?.map { it.id })
        hold.release()
        environment.end()
    }

    @Test
    fun `loadNext through a fragment's lens on an entity sends the query that spreads the fragment, with the entity's id and the next page`() = runTest {
        val transport = pagedTransport()
        val environment = environment(transport)
        val handle = environment.handle(TestFriendsQuery(id = "1", page = 1))
        val hold = handle.retain()
        runCurrent()
        val data = assertIs<Phase.Ready<TestFriendsQuery.Data>>(handle.phase).data
        val friends = assertNotNull(data.character?.testFriends?.friends)
        assertEquals(listOf("Morty Smith", "Summer Smith"), friends.nodes?.map { it.name })
        assertTrue(friends.hasNext)

        friends.loadNext()
        val request = transport.requests.last()
        assertEquals("TestFriendsQuery", request.operationName)
        assertEquals(mapOf("id" to Variable.String("1"), "page" to Variable.Int(2)), request.variables.values)
        assertEquals(listOf("Morty Smith", "Summer Smith", "Beth Smith", "Jerry Smith"), friends.nodes?.map { it.name })
        assertFalse(friends.hasNext)
        assertNotNull(environment.store.existing("Character:1:__TestFriends_nodes_paged(perPage:2)"), "the merged record hangs off the character")
        hold.release()
        environment.end()
    }

    @Test
    fun `a lens made by hand has no operation to page through, and loadNext throws when there is a page to load`() = runTest {
        val store = Store()
        val operation = TestPagedNotesQuery(page = 1, authorId = "1")
        store.commit(Ingest.normalize(pagedNotes("1"), store.resolve(TestPagedNotesQuery.plan, operation.variables), Store.ROOT_KEY))
        val data = TestPagedNotesQuery.data(Anchor(store.root, Owner(operation.variables, store)))
        val page = assertNotNull(data.page)
        assertEquals(listOf("n1", "n2"), page.notes?.map { it.id })
        assertTrue(page.hasNext)
        assertFailsWith<EnvironmentError.OutsideEnvironment> { page.loadNext() }
        assertFalse(page.isLoadingNext)
    }

    @Test
    fun `a refetch of the owning handle after two pages fetches the first page again and replaces the merged list with it`() = runTest {
        val transport = pagedTransport()
        val environment = environment(transport)
        val (handle, page, hold) = notes(environment)
        page.loadNext()
        assertEquals(listOf("n1", "n2", "n3", "n4"), page.notes?.map { it.id })
        assertEquals(2, page.pageInfo.currentPage)

        handle.refetch()
        assertEquals(mapOf("page" to Variable.Int(1), "authorId" to Variable.String("1")), transport.requests.last().variables.values)
        assertEquals(listOf("n1", "n2"), page.notes?.map { it.id })
        assertEquals(1, page.pageInfo.currentPage)
        assertTrue(page.hasNext)

        // The list starts again from its first page, so the next one is 2.
        page.loadNext()
        assertEquals(mapOf("page" to Variable.Int(2), "authorId" to Variable.String("1")), transport.requests.last().variables.values)
        assertEquals(listOf("n1", "n2", "n3", "n4"), page.notes?.map { it.id })
        hold.release()
        environment.end()
    }

    @Test
    fun `two lists paged under one server page keep their own hasNext, though the page's one page info reads the last list's`() = runTest {
        val transport = pagedTransport()
        val environment = environment(transport)
        val (_, notes, notesHold) = notes(environment)
        val charactersHandle = environment.handle(TestPagedCharactersQuery(page = 1))
        val charactersHold = charactersHandle.retain()
        runCurrent()
        val characters = assertNotNull(assertIs<Phase.Ready<TestPagedCharactersQuery.Data>>(charactersHandle.phase).data.page)
        assertEquals(listOf("Rick Sanchez", "Morty Smith"), characters.characters?.map { it.name })

        // One server record holds both lists' first pages and one page info, which says what the characters' page said.
        val shared = assertNotNull(environment.store.existing("client:root:page(page:1,perPage:2):pageInfo"))
        assertEquals(Value.Bool(false), shared.peek(Registry.slot(Types.PageInfo, "hasNextPage")))
        assertTrue(notes.hasNext)
        assertTrue(notes.pageInfo.hasNextPage)
        assertFalse(characters.hasNext)

        characters.loadNext()
        assertEquals(2, transport.requestCount, "the characters have no next page")
        notes.loadNext()
        assertEquals("TestPagedNotesQuery", transport.requests.last().operationName)
        assertEquals(listOf("n1", "n2", "n3", "n4"), notes.notes?.map { it.id })
        assertEquals(listOf("Rick Sanchez", "Morty Smith"), characters.characters?.map { it.name })
        notesHold.release()
        charactersHold.release()
        environment.end()
    }
}
