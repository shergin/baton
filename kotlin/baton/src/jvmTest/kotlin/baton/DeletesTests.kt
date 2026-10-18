package baton

import androidx.compose.runtime.snapshots.Snapshot
import baton.spec.TestAssetsQuery
import baton.spec.TestDeleteNote
import baton.spec.TestDiscardAsset
import baton.spec.TestDiscardNote
import baton.spec.TestNotesQuery
import baton.spec.TestNotes_character
import baton.spec.Types
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * A mutation that names the record it deletes by its type and a variable
 * (`@deletes`), through the environment over the operations generated from
 * `spec/sources`. Mirrors `swift/Tests/BatonTests/DeletesTests.swift`; the
 * scripts `deletes` and `deletes-image` hold the rest.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DeletesTests {
    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher. */
    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher)
    }

    /** The recorded answers to the notes query, the assets query and the two discards. */
    private fun answers(): Map<String, ByteArray> = mapOf(
        "TestNotesQuery" to Spec.bytes("tests/notes-page-1.json"),
        "TestAssetsQuery" to Spec.bytes("tests/asset-list.json"),
        "TestDiscardNote" to Spec.bytes("tests/discard-note-n2.json"),
        "TestDiscardAsset" to Spec.bytes("tests/discard-asset-a1.json"),
    )

    /** The notes query, fetched and held as a screen holds it. */
    private fun TestScope.notes(environment: Environment): Pair<TestNotes_character, Hold> {
        val handle = environment.handle(TestNotesQuery(id = "1"))
        val hold = handle.retain()
        runCurrent()
        val data = assertIs<Phase.Ready<TestNotesQuery.Data>>(handle.phase).data
        return assertNotNull(data.character).testNotes to hold
    }

    /** The assets query, fetched and held as a screen holds it. */
    private fun TestScope.assets(environment: Environment): Pair<TestAssetsQuery.Data, Hold> {
        val handle = environment.handle(TestAssetsQuery())
        val hold = handle.retain()
        runCurrent()
        return assertIs<Phase.Ready<TestAssetsQuery.Data>>(handle.phase).data to hold
    }

    /** The states [read] registers in a snapshot that observes its reads. */
    private fun statesRead(read: () -> Unit): Set<Any> {
        val states = HashSet<Any>()
        val snapshot = Snapshot.takeSnapshot { states.add(it) }
        try {
            snapshot.enter(read)
        } finally {
            snapshot.dispose()
        }
        return states
    }

    /**
     * For each of [bodies], the states a body read, the number of apply
     * notifications that touch one of them while [writes] runs: how often
     * the body is evaluated again.
     */
    private inline fun timesTold(vararg bodies: Set<Any>, writes: () -> Unit): List<Int> {
        val told = IntArray(bodies.size)
        val observer = Snapshot.registerApplyObserver { changed, _ ->
            for ((index, states) in bodies.withIndex()) if (changed.any { it in states }) told[index]++
        }
        try {
            writes()
            Snapshot.sendApplyNotifications()
        } finally {
            observer.dispose()
        }
        return told.toList()
    }

    @Test
    fun `a mutation that names the record it deletes by a variable removes it from a connection and from a plain list a screen reads, and each body that read them is told once`() = runTest {
        val environment = environment(ScriptedTransport(answers()))
        val (character, notesHold) = notes(environment)
        val (assets, assetsHold) = assets(environment)
        assertEquals(listOf("n1", "n2"), character.notes.nodes.map { it.id })
        assertEquals(listOf("Portal gun", "Plumbus"), assets.assets?.map { it.name })

        val connection = statesRead { character.notes.nodes }
        val list = statesRead { assets.assets }
        val noteTold = timesTold(connection) {
            val discarded = async { environment.mutate(TestDiscardNote(id = "n2")) }
            runCurrent()
            assertEquals(true, discarded.await().discardNote?.deleted)
        }
        assertEquals(listOf(1), noteTold, "the body that read the connection is told once")
        assertEquals(listOf("n1"), character.notes.nodes.map { it.id })
        assertTrue(assertNotNull(environment.store.existing("Note:n2")).deleted)

        lateinit var discardedAsset: Deferred<TestDiscardAsset.Data>
        val listTold = timesTold(list, connection) {
            discardedAsset = async { environment.mutate(TestDiscardAsset(uuid = "a1")) }
            runCurrent()
            discardedAsset.await()
        }
        assertEquals(listOf(1, 0), listTold, "the body that read the list is told once, and the connection's body not at all")
        assertEquals(listOf("Plumbus"), assets.assets?.map { it.name })
        assertTrue(assertNotNull(environment.store.existing("Asset:a1")).deleted)
        notesHold.release()
        assetsHold.release()
        environment.end()
    }

    @Test
    fun `an optimistic response's deletion shows before the request is answered, and a transport failure reverts it so the record reads again`() = runTest {
        val transport = ScriptedTransport(mapOf("TestNotesQuery" to Spec.bytes("tests/notes-page-1.json")))
        val environment = environment(transport)
        val (character, hold) = notes(environment)
        val second = character.notes.nodes.last()
        assertEquals("Portal gun needs charging", second.text)

        val connection = statesRead { character.notes.nodes }
        lateinit var discarding: Deferred<Result<TestDiscardNote.Data>>
        // The response carries nothing: what is deleted is the variable's.
        val applied = timesTold(connection) {
            discarding = async { runCatching { environment.mutate(TestDiscardNote(id = "n2"), TestDiscardNote.OptimisticResponse().payload) } }
            runCurrent()
        }
        assertEquals(listOf(1), applied, "the layer tells the body")
        assertEquals(1, transport.held.size, "the server has not answered")
        assertEquals(listOf("n1"), character.notes.nodes.map { it.id })
        assertNull(second.text)

        val reverted = timesTold(connection) {
            transport.held.single().refuse(TransportError(500, "no"))
            runCurrent()
            assertIs<TransportError>(discarding.await().exceptionOrNull())
        }
        assertEquals(listOf(1), reverted, "the revert tells the body again")
        assertEquals(listOf("n1", "n2"), character.notes.nodes.map { it.id })
        assertEquals("Portal gun needs charging", second.text)
        assertEquals(0, environment.store.optimisticLayerCount)
        hold.release()
        environment.end()
    }

    @Test
    fun `an optimistic deletion the server's answer resolves stays deleted, whatever the answer's boolean says`() = runTest {
        val transport = ScriptedTransport(mapOf("TestNotesQuery" to Spec.bytes("tests/notes-page-1.json")))
        val environment = environment(transport)
        val (character, hold) = notes(environment)
        val optimistic = TestDiscardNote.OptimisticResponse(TestDiscardNote.OptimisticResponse.DiscardNote(deleted = true)).payload
        val discarding = async { environment.mutate(TestDiscardNote(id = "n1"), optimistic) }
        runCurrent()
        assertEquals(listOf("n2"), character.notes.nodes.map { it.id })

        val connection = statesRead { character.notes.nodes }
        val refused = TestDiscardNote.OptimisticResponse(TestDiscardNote.OptimisticResponse.DiscardNote(deleted = false)).payload
        val told = timesTold(connection) {
            transport.held.single().respond(refused.bytes)
            runCurrent()
            assertEquals(false, discarding.await().discardNote?.deleted)
        }
        assertEquals(listOf(0), told, "the server's commit replaces the layer with the same deletion")
        assertEquals(listOf("n2"), character.notes.nodes.map { it.id })
        assertTrue(assertNotNull(environment.store.existing("Note:n1")).deleted)
        assertEquals(0, environment.store.optimisticLayerCount)
        hold.release()
        environment.end()
    }

    @Test
    fun `a payload committed by hand for the mutation deletes the record its variable names`() = runTest {
        val environment = environment(ScriptedTransport(answers()))
        val (character, notesHold) = notes(environment)
        val (assets, assetsHold) = assets(environment)

        environment.commitPayload(TestDiscardNote(id = "n2"), Payload(Spec.bytes("tests/discard-note-n2.json")))
        assertEquals(listOf("n1"), character.notes.nodes.map { it.id })

        // A payload that answers nothing of the selection deletes as well.
        environment.commitPayload(TestDiscardAsset(uuid = "a1"), TestDiscardAsset.OptimisticResponse().payload)
        assertEquals(listOf("Plumbus"), assets.assets?.map { it.name })
        assertTrue(assertNotNull(environment.store.existing("Asset:a1")).deleted)
        notesHold.release()
        assetsHold.release()
        environment.end()
    }

    @Test
    fun `the keys a plan's deletions name are composed from the variables, a String key and an Int key as they are, and an unset or null variable names none`() {
        assertEquals(listOf("Note:n2"), TestDiscardNote.plan.deletionKeys(TestDiscardNote(id = "n2").variables))
        assertEquals(listOf("Asset:a1"), TestDiscardAsset.plan.deletionKeys(TestDiscardAsset(uuid = "a1").variables))
        assertEquals(emptyList(), TestDiscardNote.plan.deletionKeys(Variables(mapOf("id" to Variable.Null))))
        assertEquals(emptyList(), TestDiscardNote.plan.deletionKeys(Variables.none))
        assertEquals(emptyList(), TestDeleteNote.plan.deletionKeys(TestDeleteNote(id = "n2").variables), "@deleteRecord names its record in the payload")

        val plan = Plan(
            TestDiscardNote.plan.root,
            deletions = listOf(Deletion(Types.Note, "id"), Deletion(Types.Character, "character"), Deletion(Types.Asset, "uuid")),
        )
        val variables = Variables(mapOf("id" to Variable.String("n1"), "character" to Variable.Int(7L), "uuid" to Variable.Null))
        assertEquals(listOf("Note:n1", "Character:7"), plan.deletionKeys(variables))
    }
}
