package baton

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.v2.createComposeRule
import baton.spec.TestHeaderQuery
import baton.spec.TestHeader_character
import baton.spec.TestNoteAdded
import baton.spec.TestRename
import baton.testing.ScriptedTransport
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test

/** The composables in a composition: a provided environment, the handles they remember, and what recomposes. */
class ComposeTests {
    @get:Rule
    val rule = createComposeRule()

    /** The environment the composition made, on its own thread and dispatcher, as an app makes one on its main thread. */
    private var environment: Environment? = null

    /**
     * Provides an environment over [transport], made once on the composition's
     * thread, the desktop's event thread, and committing there through the
     * main dispatcher, as an app makes one.
     */
    @Composable
    private fun Provided(transport: ScriptedTransport, content: @Composable () -> Unit) {
        val made = remember { Environment(transport, transport, Store()).also { environment = it } }
        CompositionLocalProvider(LocalBaton provides made, content = content)
    }

    /** Runs a suspending call on the composition's thread, which owns the store. */
    private fun <T> onStoreThread(call: suspend () -> T): T {
        var result: Result<T>? = null
        rule.runOnIdle { result = runCatching { runBlocking { call() } } }
        return result!!.getOrThrow()
    }

    @Test
    fun a_composable_under_LocalBaton_reads_loading_then_ready_when_the_transport_answers() {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val phases = ArrayList<String>()
        rule.setContent {
            Provided(transport) {
                val header = rememberQuery(TestHeaderQuery(id = "5"))
                phases += when (val phase = header.phase) {
                    Phase.Loading -> "loading"
                    is Phase.Ready -> "ready: ${phase.data.character?.testHeader?.name}"
                    is Phase.Failed -> "failed: ${phase.error}"
                }
            }
        }
        rule.waitForIdle()
        assertEquals(listOf("loading"), phases)
        rule.runOnIdle { transport.held.single().respond(Spec.bytes("tests/character-header-5.json")) }
        rule.waitUntil(5_000) { phases.last() != "loading" }
        assertEquals(listOf("loading", "ready: Jerry Smith"), phases)
        assertEquals(1, transport.requestCount)
    }

    @Composable
    private fun Name(character: TestHeader_character, compositions: MutableList<String>) {
        compositions += "name ${character.name}"
    }

    @Composable
    private fun Status(character: TestHeader_character, compositions: MutableList<String>) {
        compositions += "status ${character.status}"
    }

    @Test
    fun a_write_to_one_field_recomposes_only_the_row_reading_it() {
        val transport = ScriptedTransport(mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json")))
        val compositions = ArrayList<String>()
        rule.setContent {
            Provided(transport) {
                val header = rememberQuery(TestHeaderQuery(id = "5"))
                val character = (header.phase as? Phase.Ready)?.data?.character?.testHeader ?: return@Provided
                Name(character, compositions)
                Status(character, compositions)
            }
        }
        rule.waitUntil(5_000) { compositions.isNotEmpty() }
        assertEquals(listOf("name Jerry Smith", "status Alive"), compositions)
        compositions.clear()
        onStoreThread {
            val rename = TestRename(id = "5", name = "Jerry Prime")
            checkNotNull(environment).commitPayload(rename, Payload("{\"data\":{\"rename\":{\"character\":{\"id\":\"5\",\"name\":\"Jerry Prime\"}}}}"))
        }
        rule.waitForIdle()
        assertEquals(listOf("name Jerry Prime"), compositions, "the status row read no slot the write changed")
    }

    @Test
    fun an_equal_value_recomposed_keeps_its_handle_and_leaving_composition_releases_it() {
        val transport = ScriptedTransport(mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json")))
        var shown by mutableStateOf(true)
        var generation by mutableStateOf(0)
        val handles = ArrayList<OperationHandle<*>>()
        val generations = ArrayList<Int>()
        rule.setContent {
            Provided(transport) {
                if (shown) {
                    // A new value each recomposition, equal to the last; reading the generation recomposes it.
                    val header = rememberQuery(TestHeaderQuery(id = "5"))
                    handles += assertNotNull(header.resolution.handle)
                    generations += generation
                }
            }
        }
        rule.waitForIdle()
        rule.runOnIdle { generation += 1 }
        rule.waitForIdle()
        assertEquals(listOf(0, 1), generations)
        assertSame(handles[0], handles[1], "an equal value keeps its handle")
        assertEquals(1, transport.requestCount, "and makes no request of its own")
        val handle = handles[0]
        rule.runOnIdle { assertEquals(1, handle.retainCount) }
        rule.runOnIdle { shown = false }
        rule.waitForIdle()
        rule.runOnIdle { assertEquals(0, handle.retainCount, "leaving the composition released the handle") }
    }

    @Test
    fun a_changed_value_resolves_to_another_handle_and_releases_the_first() {
        val transport = ScriptedTransport(
            mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json")),
            responder = { request -> if (request.variables["id"] == Variable.String("3")) Spec.bytes("tests/character-header-3.json") else null },
        )
        var id by mutableStateOf("5")
        val handles = LinkedHashSet<OperationHandle<*>>()
        rule.setContent {
            Provided(transport) {
                handles += assertNotNull(rememberQuery(TestHeaderQuery(id = id)).resolution.handle)
            }
        }
        rule.waitForIdle()
        rule.runOnIdle { id = "3" }
        rule.waitForIdle()
        val (first, second) = handles.toList()
        rule.runOnIdle {
            assertEquals(0, first.retainCount)
            assertEquals(1, second.retainCount)
        }
        assertEquals(2, transport.requestCount)
    }

    @Test
    fun outside_every_provider_the_phase_is_failed_with_not_injected_and_no_handle_is_made() {
        var phase: Phase<*>? = null
        var resolution: Resolution<*>? = null
        rule.setContent {
            val header = rememberQuery(TestHeaderQuery(id = "5"))
            phase = header.phase
            resolution = header.resolution
        }
        rule.waitForIdle()
        assertEquals(Phase.Failed(EnvironmentError.NotInjected), phase)
        assertSame(Resolution.NotInjected, resolution)
    }

    @Test
    fun a_remembered_mutation_commits_through_the_environment_and_outside_every_provider_throws_not_injected() {
        val transport = ScriptedTransport(mapOf("TestRename" to Spec.bytes("tests/rename-1.json")))
        var provided: MutationAction<TestRename, TestRename.Data>? = null
        var outside: MutationAction<TestRename, TestRename.Data>? = null
        rule.setContent {
            Provided(transport) { provided = rememberMutation(TestRename) }
            outside = rememberMutation(TestRename)
        }
        rule.waitForIdle()
        val name = onStoreThread { checkNotNull(provided).commit(TestRename(id = "1", name = "Rick Prime")).rename?.character?.name }
        assertEquals("Rick Prime", name)
        assertFailsWith<EnvironmentError> { onStoreThread { checkNotNull(outside).commit(TestRename(id = "1", name = "Rick Prime")) } }
    }

    @Test
    fun a_remembered_subscription_holds_its_stream_open_while_it_stays_and_closes_it_when_it_leaves() {
        val transport = ScriptedTransport()
        var shown by mutableStateOf(true)
        var handle: SubscriptionHandle<*>? = null
        var outside: SubscriptionHandle<*>? = null
        rule.setContent {
            Provided(transport) {
                if (shown) handle = rememberSubscription(TestNoteAdded(characterId = "1", connections = emptyList())).subscription
            }
            outside = rememberSubscription(TestNoteAdded(characterId = "1", connections = emptyList())).subscription
        }
        rule.waitUntil(5_000) { transport.driven.size == 1 }
        assertNull(outside, "outside every provider no handle is made")
        rule.runOnIdle { transport.driven.single().send(Spec.bytes("tests/note-added-1.json")) }
        rule.waitUntil(5_000) { handle?.events == 1 }
        assertEquals(Stream.Open, handle?.stream)
        rule.runOnIdle { shown = false }
        rule.waitUntil(5_000) { transport.driven.isEmpty() }
        assertIs<Stream.Idle>(handle?.stream)
        assertTrue(transport.requestCount == 1)
    }
}
