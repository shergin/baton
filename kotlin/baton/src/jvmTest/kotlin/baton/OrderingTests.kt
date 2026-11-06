package baton

import baton.spec.TestDiscardNote
import baton.spec.TestNotesQuery
import baton.spec.TestRename
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * A late response yields to a newer deletion and to a newer response of its
 * root, through the store and the environment. Mirrors
 * `swift/Tests/BatonTests/OrderingTests.swift`; the script `ordering` holds
 * the rest.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class OrderingTests {
    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher. */
    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher)
    }

    private val notes = TestNotesQuery(id = "1")

    /** The recorded answers to the notes query and the discard of `Note:n2`. */
    private fun answers(): Map<String, ByteArray> = mapOf(
        "TestNotesQuery" to Spec.bytes("tests/notes-page-1.json"),
        "TestDiscardNote" to Spec.bytes("tests/discard-note-n2.json"),
    )

    /** The notes page as a server batch, normalized under the query's root. */
    private fun notesChanges(store: Store): ChangeSet =
        Ingest.normalize(Spec.bytes("tests/notes-page-1.json"), store.resolve(TestNotesQuery.plan, notes.variables), Store.ROOT_KEY, complete = true)

    /** The notes query's root in [store]. */
    private fun notesRoot(store: Store): Store.Root =
        store.root(Store.rootKey("TestNotesQuery", notes.variables), store.resolve(TestNotesQuery.plan, notes.variables), store.root)

    /** The name of `Character:1` as the notes query reads it from the store. */
    private fun name(environment: Environment): String? {
        val phase = environment.handle(notes, FetchPolicy.STORE_ONLY).phase
        if (phase !is Phase.Ready) return null
        return phase.data.character?.testNotes?.name
    }

    /** Starts a fetch of the notes query and runs it until its request is held, so the requests are issued in the order of the calls. */
    private fun TestScope.startFetch(environment: Environment, transport: ScriptedTransport): Deferred<Unit> {
        val before = transport.held.size
        val fetch = async { environment.fetch(notes) }
        runCurrent()
        assertEquals(before + 1, transport.held.size, "the fetch's request is held")
        return fetch
    }

    /** The operations the log reported a superseded response of. */
    private fun Environment.superseded(): MutableList<String> {
        val operations = mutableListOf<String>()
        log = { event -> if (event is LogEvent.ResponseSuperseded) operations.add(event.operation) }
        return operations
    }

    @Test
    fun `the store numbers each request one more than the last`() {
        val store = Store()
        assertEquals(0, store.generation)
        assertEquals(1, store.issue())
        assertEquals(2, store.issue())
        assertEquals(3, store.issue())
        assertEquals(3, store.generation)
    }

    @Test
    fun `the environment issues a number for each fetch and each mutation, and none for a payload committed by hand`() = runTest {
        val environment = environment(ScriptedTransport(answers(), holdsMutations = false))
        environment.fetch(notes)
        assertEquals(1, environment.store.generation)
        environment.mutate(TestDiscardNote(id = "n2"))
        assertEquals(2, environment.store.generation)
        environment.commitPayload(notes, Payload(Spec.bytes("tests/notes-page-1.json")))
        assertEquals(2, environment.store.generation, "a payload committed by hand answers no request")
        environment.end()
    }

    @Test
    fun `a record deleted while a request was current is not revived by a response to that request or an older one, and is revived by a response to a newer one`() = runTest {
        val environment = environment(ScriptedTransport(answers(), holdsMutations = false))
        environment.fetch(notes)
        environment.mutate(TestDiscardNote(id = "n2"))
        val store = environment.store
        val note = assertNotNull(store.existing("Note:n2"))
        assertTrue(note.deleted)
        val deletedAt = note.deletedAt
        assertEquals(store.generation, deletedAt, "the deletion remembers the request current when it was made")

        store.commit(notesChanges(store), null, issued = deletedAt - 1)
        assertTrue(note.deleted, "a response to a request older than the deletion leaves the record deleted")
        store.commit(notesChanges(store), null, issued = deletedAt)
        assertTrue(note.deleted, "a response to the request current at the deletion leaves the record deleted")
        store.commit(notesChanges(store), null, issued = deletedAt + 1)
        assertFalse(note.deleted, "a response to a newer request names the record again and revives it")
        environment.end()
    }

    @Test
    fun `a payload that carries no request's number revives a deleted record, as a payload committed by hand does`() = runTest {
        val environment = environment(ScriptedTransport(answers(), holdsMutations = false))
        environment.fetch(notes)
        environment.mutate(TestDiscardNote(id = "n2"))
        val store = environment.store
        val note = assertNotNull(store.existing("Note:n2"))
        assertTrue(note.deleted)

        store.commit(notesChanges(store), null)
        assertFalse(note.deleted)

        environment.mutate(TestDiscardNote(id = "n2"))
        assertTrue(note.deleted)
        environment.commitPayload(notes, Payload(Spec.bytes("tests/notes-page-1.json")))
        assertFalse(note.deleted, "the environment's payload committed by hand revives it too")
        environment.end()
    }

    @Test
    fun `a root remembers the number of the request whose response last committed for it`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestNotesQuery")
        val environment = environment(transport)
        val root = notesRoot(environment.store)
        assertEquals(0, root.issued)

        val first = startFetch(environment, transport)
        val second = startFetch(environment, transport)
        val (firstHeld, secondHeld) = transport.held
        firstHeld.respond(Spec.bytes("tests/notes-page-1.json"))
        runCurrent()
        first.await()
        assertEquals(1, root.issued)
        secondHeld.respond(Spec.bytes("tests/notes-page-1.json"))
        runCurrent()
        second.await()
        assertEquals(2, root.issued)

        environment.commitPayload(notes, Payload(Spec.bytes("tests/notes-page-1.json")))
        assertEquals(2, root.issued, "a payload committed by hand answers no request")
        environment.end()
    }

    @Test
    fun `a query's response to a request older than one whose response already landed for the same root is dropped at the door and logged as superseded`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestNotesQuery")
        val environment = environment(transport)
        val superseded = environment.superseded()
        val root = notesRoot(environment.store)

        val older = startFetch(environment, transport)
        val newer = startFetch(environment, transport)
        val (olderHeld, newerHeld) = transport.held

        newerHeld.respond(Spec.bytes("tests/notes-page-1-renamed.json"))
        runCurrent()
        newer.await()
        assertEquals("Rick C-137", name(environment))
        assertEquals(emptyList(), superseded)

        olderHeld.respond(Spec.bytes("tests/notes-page-1.json"))
        runCurrent()
        older.await()
        assertEquals("Rick C-137", name(environment), "the older response does not overwrite the newer one")
        assertEquals(listOf("TestNotesQuery"), superseded)
        assertEquals(2, root.issued, "a dropped response does not move the root's number")
        environment.end()
    }

    @Test
    fun `a mutation's response to an older request of the same operation and variables is committed after a newer one, since the rule is for a query's root`() = runTest {
        val transport = ScriptedTransport(mapOf("TestNotesQuery" to Spec.bytes("tests/notes-page-1.json")))
        val environment = environment(transport)
        val superseded = environment.superseded()
        environment.fetch(notes)
        assertEquals("Rick Sanchez", name(environment))

        val rename = TestRename(id = "1", name = "Rick Prime")
        val older = async { environment.mutate(rename) }
        runCurrent()
        val newer = async { environment.mutate(rename) }
        runCurrent()
        val (olderHeld, newerHeld) = transport.held

        newerHeld.respond(Spec.bytes("tests/rename-1.json"))
        runCurrent()
        newer.await()
        assertEquals("Rick Prime", name(environment))

        environment.fetch(notes)
        assertEquals("Rick Sanchez", name(environment))

        olderHeld.respond(Spec.bytes("tests/rename-1.json"))
        runCurrent()
        older.await()
        assertEquals("Rick Prime", name(environment), "the older mutation's response is committed")
        assertEquals(emptyList(), superseded)
        environment.end()
    }
}
