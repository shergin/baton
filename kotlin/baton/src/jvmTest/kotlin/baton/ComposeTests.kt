package baton

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.ComposeTestRule
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import org.junit.After
import org.junit.Rule
import org.junit.Test

/** The composables in a composition: a provided environment, the handles they remember, and what recomposes. */
class ComposeTests {
    @get:Rule
    val rule = createComposeRule()

    /** The environment the composition made, on its own thread and dispatcher, as an app makes one on its main thread. */
    private var environment: Environment? = null

    /**
     * Ends the environment on the composition's thread while the rule still
     * holds the composition, however the test went. An environment left
     * running keeps its write observer, which posts a send of the apply
     * notifications to the event thread after every snapshot write the later
     * tests make.
     */
    @After
    fun endTheEnvironment() {
        val made = environment ?: return
        rule.onStoreThread { made.end() }
    }

    /**
     * Provides an environment over [transport], made once on the composition's
     * thread, the desktop's event thread, and committing there through the
     * main dispatcher, as an app makes one. While [providing] is false the
     * same content is composed with no environment above it, and the
     * environment waits to be provided again.
     */
    @Composable
    private fun Provided(transport: ScriptedTransport, providing: Boolean = true, content: @Composable () -> Unit) {
        val made = remember { Environment(transport, transport, Store()).also { environment = it } }
        CompositionLocalProvider(LocalBaton provides made.takeIf { providing }, content = content)
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
        rule.onStoreThread {
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
                    handles += assertNotNull(header.handle)
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
                handles += assertNotNull(rememberQuery(TestHeaderQuery(id = id)).handle)
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
    fun a_policy_passed_anew_is_applied_on_that_attach() {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        var policy by mutableStateOf(FetchPolicy.STORE_ONLY)
        val handles = ArrayList<OperationHandle<*>>()
        val phases = ArrayList<Phase<TestHeaderQuery.Data>>()
        rule.setContent {
            Provided(transport) {
                val header = rememberQuery(TestHeaderQuery(id = "5"), policy)
                handles += assertNotNull(header.handle)
                phases += header.phase
            }
        }
        rule.waitForIdle()
        assertEquals(0, transport.requestCount, "a storeOnly attach asks nothing of the network")
        assertEquals(Phase.Failed(MissingDataError("TestHeaderQuery")), phases.last())
        rule.runOnIdle { policy = FetchPolicy.STORE_OR_NETWORK }
        rule.waitForIdle()
        assertEquals(1, transport.requestCount, "the policy passed anew fetched on its attach")
        assertEquals(Phase.Loading, phases.last())
        val handle = handles.last()
        assertSame(handles.first(), handle, "an equal value keeps the handle equal values share")
        rule.runOnIdle { assertEquals(1, handle.retainCount, "the attach under the earlier policy released its hold") }
        rule.runOnIdle { transport.held.single().respond(Spec.bytes("tests/character-header-5.json")) }
        rule.waitUntil(5_000) { phases.last() is Phase.Ready }
    }

    @Test
    fun a_composable_that_leaves_the_provider_and_returns_resolves_anew_and_the_earlier_hold_is_released() {
        val transport = ScriptedTransport(mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json")))
        var providing by mutableStateOf(true)
        val states = ArrayList<QueryState<TestHeaderQuery, TestHeaderQuery.Data>>()
        val phases = ArrayList<Phase<TestHeaderQuery.Data>>()
        rule.setContent {
            // The same composable throughout: only the environment above it goes and comes back.
            Provided(transport, providing) {
                val header = rememberQuery(TestHeaderQuery(id = "5"))
                states += header
                phases += header.phase
            }
        }
        rule.waitUntil(5_000) { phases.last() is Phase.Ready }
        val handle = assertNotNull(states.last().handle)
        rule.runOnIdle { assertEquals(1, handle.retainCount) }

        rule.runOnIdle { providing = false }
        rule.waitForIdle()
        assertNull(states.last().handle, "with no environment above it no handle is made")
        assertEquals(Phase.Failed(EnvironmentError.NotInjected), phases.last())
        rule.runOnIdle { assertEquals(0, handle.retainCount, "leaving the provider released the earlier hold") }

        rule.runOnIdle { providing = true }
        rule.waitForIdle()
        val again = assertNotNull(states.last().handle, "back under the provider the value resolves anew")
        assertSame(handle, again, "to the handle its root kept while it waited in the release buffer")
        assertIs<Phase.Ready<*>>(phases.last())
        rule.runOnIdle { assertEquals(1, again.retainCount) }
        assertEquals(1, transport.requestCount, "the data the first attach fetched serves the return")
    }

    @Test
    fun outside_every_provider_no_handle_is_made_the_phase_is_failed_with_not_injected_and_a_refetch_throws_it() {
        var remembered: QueryState<TestHeaderQuery, TestHeaderQuery.Data>? = null
        rule.setContent {
            remembered = rememberQuery(TestHeaderQuery(id = "5"))
        }
        rule.waitForIdle()
        val header = assertNotNull(remembered)
        assertNull(header.handle)
        assertEquals(Phase.Failed(EnvironmentError.NotInjected), header.phase)
        assertFailsWith<EnvironmentError.NotInjected> { rule.onStoreThread { header.refetch() } }
    }

    @Test
    fun the_value_a_composable_passes_is_never_written_to_so_one_value_serves_inside_and_outside_the_provider() {
        val transport = ScriptedTransport(mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json")))
        val passed = TestHeaderQuery(id = "5")
        var inside: QueryState<TestHeaderQuery, TestHeaderQuery.Data>? = null
        var outside: QueryState<TestHeaderQuery, TestHeaderQuery.Data>? = null
        rule.setContent {
            Provided(transport) { inside = rememberQuery(passed) }
            outside = rememberQuery(passed)
        }
        rule.waitForIdle()
        val provided = assertNotNull(inside)
        val unprovided = assertNotNull(outside)
        assertSame(passed, provided.operation)
        assertSame(passed, unprovided.operation)
        assertNotNull(provided.handle, "under the provider the value resolves to a handle")
        assertNull(unprovided.handle, "outside it the same value resolves to none")
        assertEquals(TestHeaderQuery(id = "5"), passed)
    }

    @Test
    fun a_remembered_mutation_commits_through_the_environment_and_outside_every_provider_throws_not_injected() {
        val transport = ScriptedTransport(mapOf("TestRename" to Spec.bytes("tests/rename-1.json")))
        var provided: MutationAction<TestRename, TestRename.Data>? = null
        var outside: MutationAction<TestRename, TestRename.Data>? = null
        rule.setContent {
            Provided(transport) {
                val rename = rememberMutation(TestRename)
                provided = rename
            }
            val rename = rememberMutation(TestRename)
            outside = rename
        }
        rule.waitForIdle()
        val name = rule.onStoreThread { checkNotNull(provided).commit(TestRename(id = "1", name = "Rick Prime")).rename?.character?.name }
        assertEquals("Rick Prime", name)
        assertFailsWith<EnvironmentError> { rule.onStoreThread { checkNotNull(outside).commit(TestRename(id = "1", name = "Rick Prime")) } }
    }

    @Test
    fun a_remembered_subscription_holds_its_stream_open_while_it_stays_and_closes_it_when_it_leaves() {
        val transport = ScriptedTransport()
        var shown by mutableStateOf(true)
        var handle: SubscriptionHandle<*>? = null
        var outside: SubscriptionHandle<*>? = null
        rule.setContent {
            Provided(transport) {
                if (shown) handle = rememberSubscription(TestNoteAdded(characterId = "1", connections = emptyList()))
            }
            outside = rememberSubscription(TestNoteAdded(characterId = "1", connections = emptyList()))
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

/**
 * Runs a suspending call on the composition's thread, which owns the store,
 * and waits for it from the test's thread. The call is a coroutine on the
 * main dispatcher, which is that thread: `runBlocking` there would block the
 * thread the call comes back to after its ingest, and never return.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal fun <T> ComposeTestRule.onStoreThread(call: suspend () -> T): T {
    val running = runOnIdle { CoroutineScope(Dispatchers.Main.immediate).async { call() } }
    waitUntil(5_000) { running.isCompleted }
    return running.getCompleted()
}
