package baton

import baton.spec.TestAuthorNotesQuery
import baton.spec.TestAuthorNotes_note
import baton.spec.TestHiddenRecentNotesQuery
import baton.spec.TestNotesQuery
import baton.spec.TestNotes_character
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
 * Loading a page through a lens, and a fragment's refetch, which the
 * contract leaves unheld: the generated `TestNotes_character` lens over the
 * notes fixtures, as `swift/Tests/BatonTests/ListTests.swift` proves them.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PaginationTests {
    private fun notesPage(number: Int): ByteArray = Spec.bytes("tests/notes-page-$number.json")

    /** Answers the notes query with its first page and the pagination query with the page after the cursor it carries. */
    private fun notesTransport(): RecordedTransport = RecordedTransport { request ->
        if (request.operationName == "TestNotesQuery") return@RecordedTransport notesPage(1)
        when (request.variables["cursor"]) {
            Variable.String("c2") -> notesPage(2)
            Variable.String("c4") -> notesPage(3)
            else -> notesPage(1)
        }
    }

    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher. */
    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher)
    }

    /** The notes query fetched and held as a composable on screen holds it, and the fragment's lens over its character. */
    private fun TestScope.seeded(environment: Environment): Pair<TestNotes_character, Hold> {
        val handle = environment.handle(TestNotesQuery(id = "1"))
        val hold = handle.retain()
        runCurrent()
        val data = assertIs<Phase.Ready<TestNotesQuery.Data>>(handle.phase).data
        return assertNotNull(data.character?.testNotes) to hold
    }

    @Test
    fun `loadNext fetches after the end cursor, appends, and is a no-op at the end`() = runTest {
        val transport = notesTransport()
        val environment = environment(transport)
        val (character, hold) = seeded(environment)
        assertEquals(1, transport.requestCount)

        character.notes.loadNext()
        assertEquals(2, transport.requestCount)
        val request = transport.requests[1]
        assertEquals("TestNotesPaginationQuery", request.operationName)
        assertEquals(Variable.String("c2"), request.variables["cursor"])
        assertEquals(Variable.Int(2), request.variables["count"])
        assertEquals(Variable.String("1"), request.variables["id"])
        assertEquals(4, character.notes.nodes.size)
        assertFalse(character.notes.isLoadingNext)

        character.notes.loadNext(10)
        assertEquals(Variable.String("c4"), transport.requests[2].variables["cursor"])
        assertEquals(Variable.Int(10), transport.requests[2].variables["count"])
        assertEquals(5, character.notes.nodes.size)
        assertFalse(character.notes.hasNext)

        character.notes.loadNext()
        assertEquals(3, transport.requestCount, "nothing to load")

        // Each page is dated on a root of its own, which waits in the release buffer; the connection keeps its pages
        // through the notes query's root.
        assertEquals(3, environment.store.roots.size, "the notes query's root and the two pages' waiting in the buffer")
        environment.store.collect()
        assertEquals(5, character.notes.nodes.size)
        assertNotNull(environment.store.existing("Note:n5"))
        hold.release()
        environment.end()
    }

    @Test
    fun `isLoadingNext is set on the connection record while the page is in flight, and a second loadNext meanwhile sends nothing`() = runTest {
        val transport = ScriptedTransport(mapOf("TestNotesQuery" to notesPage(1)))
        transport.hold("TestNotesPaginationQuery")
        val environment = environment(transport)
        val (character, hold) = seeded(environment)
        assertFalse(character.notes.isLoadingNext)

        val loading = async { character.notes.loadNext() }
        runCurrent()
        assertTrue(character.notes.isLoadingNext)
        character.notes.loadNext()
        assertEquals(2, transport.requestCount, "a page in flight is not asked for again")

        transport.held.single().respond(notesPage(2))
        loading.await()
        assertFalse(character.notes.isLoadingNext)
        assertEquals(4, character.notes.nodes.size)
        assertEquals(2, environment.store.roots.size, "the notes query's root and the page's, dated and waiting in the buffer")
        hold.release()
        environment.end()
    }

    @Test
    fun `a page that fails clears the loading flag and leaves the connection as it was`() = runTest {
        val transport = ScriptedTransport(mapOf("TestNotesQuery" to notesPage(1)))
        transport.hold("TestNotesPaginationQuery")
        val environment = environment(transport)
        val (character, hold) = seeded(environment)

        val loading = async { runCatching { character.notes.loadNext() }.exceptionOrNull() }
        runCurrent()
        transport.held.single().refuse(TransportError(503, "down"))
        assertIs<TransportError>(loading.await())
        assertFalse(character.notes.isLoadingNext)
        assertEquals(2, character.notes.nodes.size)
        hold.release()
        environment.end()
    }

    @Test
    fun `refetch fetches the fragment again with its variables and the owner's id, and the records update in place`() = runTest {
        val transport = RecordedTransport { request ->
            if (request.operationName == "TestNotesQuery") notesPage(1) else Spec.bytes("tests/notes-refetch.json")
        }
        val environment = environment(transport)
        val (character, hold) = seeded(environment)
        val first = character.notes.nodes.first()
        assertEquals("Wubba lubba dub dub", first.text)

        character.refetch()
        val request = transport.requests.last()
        assertEquals("TestNotesPaginationQuery", request.operationName)
        assertEquals(Variable.String("1"), request.variables["id"])
        assertEquals(Variable.Int(2), request.variables["count"])
        assertEquals("Wubba lubba dub dub!", first.text, "the lens over the same record reads the new value")
        assertEquals(2, character.notes.nodes.size)
        assertEquals(2, environment.store.roots.size, "the notes query's root and the refetch query's, dated and waiting in the buffer")
        hold.release()
        environment.end()
    }

    @Test
    fun `a connection one link below its fragment's type paginates with the fragment's record's id, not the record it hangs from`() = runTest {
        val transport = RecordedTransport { request ->
            when {
                request.operationName == "TestAuthorNotesQuery" -> Spec.bytes("tests/author-notes-page-1.json")
                request.variables["cursor"] == Variable.String("c2") -> Spec.bytes("tests/author-notes-page-2.json")
                else -> Spec.bytes("tests/author-notes-page-1.json")
            }
        }
        val environment = environment(transport)
        val handle = environment.handle(TestAuthorNotesQuery(id = "n1"))
        val hold = handle.retain()
        runCurrent()
        val note: TestAuthorNotes_note = assertNotNull(assertIs<Phase.Ready<TestAuthorNotesQuery.Data>>(handle.phase).data.node?.note)
        val author = assertNotNull(note.author)
        assertEquals("1", author.id)
        assertEquals(listOf("n1", "n2"), author.notes.nodes.map { it.id })

        author.notes.loadNext()
        val request = transport.requests.last()
        assertEquals("TestAuthorNotesPaginationQuery", request.operationName)
        assertEquals(Variable.String("n1"), request.variables["id"], "the note's id, not the author's")
        assertEquals(Variable.String("c2"), request.variables["cursor"])
        assertEquals(listOf("n1", "n2", "n3", "n4"), author.notes.nodes.map { it.id })

        note.refetch()
        val refetch = transport.requests.last()
        assertEquals("TestAuthorNotesPaginationQuery", refetch.operationName)
        assertEquals(Variable.String("n1"), refetch.variables["id"])
        assertTrue(refetch.variables["cursor"] == null || refetch.variables["cursor"] == Variable.Null)
        assertEquals(3, transport.requestCount)
        hold.release()
        environment.end()
    }

    @Test
    fun `loadPrevious fetches before the start cursor and prepends`() = runTest {
        val transport = RecordedTransport { request ->
            if (request.operationName == "TestHiddenRecentNotesQuery") {
                Spec.bytes("tests/hidden-recent-notes-page-1.json")
            } else {
                Spec.bytes("tests/hidden-recent-notes-page-2.json")
            }
        }
        val environment = environment(transport)
        val handle = environment.handle(TestHiddenRecentNotesQuery(id = "1"))
        val hold = handle.retain()
        runCurrent()
        val data = assertIs<Phase.Ready<TestHiddenRecentNotesQuery.Data>>(handle.phase).data
        val notes = assertNotNull(data.character).testHiddenRecentNotes.notes
        assertEquals(listOf("n4", "n5"), notes.nodes.map { it.id })

        notes.loadPrevious()
        assertEquals("TestHiddenRecentNotesPaginationQuery", transport.requests.last().operationName)
        assertEquals(Variable.String("c4"), transport.requests.last().variables["cursor"])
        assertEquals(listOf("n2", "n3", "n4", "n5"), notes.nodes.map { it.id })
        assertFalse(notes.isLoadingPrevious)
        hold.release()
        environment.end()
    }

    @Test
    fun `a lens made by hand has no environment to page through, and says so when there is a page to load`() = runTest {
        val store = Store()
        val operation = TestNotesQuery(id = "1")
        store.commit(Ingest.normalize(notesPage(1), store.resolve(TestNotesQuery.plan, operation.variables), Store.ROOT_KEY))
        val data = TestNotesQuery.data(Anchor(store.root, Owner(operation.variables, store)))
        val character = assertNotNull(data.character?.testNotes)
        assertTrue(character.notes.hasNext)
        assertFailsWith<EnvironmentError.OutsideEnvironment> { character.notes.loadNext() }
        assertFailsWith<EnvironmentError.OutsideEnvironment> { character.refetch() }
    }
}
