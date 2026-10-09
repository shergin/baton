package baton

import androidx.compose.runtime.snapshotFlow
import baton.spec.Fixture
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** What the screen shows: the rows, or why there are none yet. */
private sealed interface Screen {
    data object Loading : Screen
    data class Rows(val names: List<String>) : Screen
    data class Failed(val error: Throwable) : Screen
}

/**
 * The view model of `docs/recipes/views.md` as the page prints it, over the
 * fixture's operation where the page names an app's.
 */
private class CharactersModel(environment: Environment) {
    // The handle the value resolves to, retained while the model lives.
    private val handle: OperationHandle<Fixture.Data> =
        environment.handle(Fixture(page = 1), FetchPolicy.Default)
    private val hold: Hold = handle.retain()

    // What the screen shows, read inside the block: the fields the block
    // reads are what the flow listens to, so a response that renames one
    // row emits new rows. A ready phase alone is equal across reads, and a
    // flow of phases would not emit for a field. The fixture's schema types
    // the list and the names nullable, where the page's operation has them
    // non-null: a missing list reads as no rows and a null name as an empty
    // one.
    val screen: Flow<Screen> = snapshotFlow {
        when (val phase = handle.phase) {
            is Phase.Ready -> Screen.Rows(phase.data.characters?.results.orEmpty().map { it.name.orEmpty() })
            Phase.Loading -> Screen.Loading
            is Phase.Failed -> Screen.Failed(phase.error)
        }
    }

    fun refetch() = handle.retry()

    fun close() = hold.release()
}

/**
 * What `docs/recipes/views.md` says of a model that holds a handle without
 * a composition: the environment sends the snapshot system's apply
 * notifications behind the runtime's writes, so the model's screen follows
 * the store with no frame clock to send them and no test sending them by
 * hand.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ViewsTests {
    private val response = Spec.bytes("rickandmorty/characters-page-1.json")

    /** The same page with its first character renamed, as a later fetch of the page answers. */
    private val renamed = Spec.text("rickandmorty/characters-page-1.json").replace("\"Rick Sanchez\"", "\"Rick Prime\"").encodeToByteArray()

    /** The renamed page with every living character dead, a field no row shows. */
    private val buried = renamed.decodeToString().replace("\"status\":\"Alive\"", "\"status\":\"Dead\"").encodeToByteArray()

    /** The rows a response makes: its characters' names, in its order. */
    private fun rows(response: ByteArray): Screen.Rows {
        val data = (Json.parse(response.decodeToString()) as Map<*, *>)["data"] as Map<*, *>
        val results = (data["characters"] as Map<*, *>)["results"] as List<*>
        return Screen.Rows(results.map { (it as Map<*, *>)["name"] as String })
    }

    /**
     * An environment over a new store whose main dispatcher, and ingest
     * dispatcher, is [main]. No released root is buffered, so a release
     * lets the records go at the pass it schedules.
     */
    private fun environment(transport: ScriptedTransport, main: TestDispatcher): Environment =
        Environment(transport, null, Store(releaseBufferSize = 0), main, main)

    @Test
    fun `the model's screen collected on the main dispatcher reads loading, then the rows once the response commits, with no notification sent by the test`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("Fixture")
        val main = StandardTestDispatcher(testScheduler)
        val environment = environment(transport, main)
        val model = CharactersModel(environment)
        val seen = ArrayList<Screen>()
        backgroundScope.launch(main) { model.screen.collect { seen += it } }
        runCurrent()
        assertEquals(listOf<Screen>(Screen.Loading), seen)

        transport.held.single().respond(response)
        runCurrent()
        assertEquals(listOf(Screen.Loading, rows(response)), seen)
        model.close()
        environment.end()
    }

    @Test
    fun `a second response that renames the first character emits new rows with the new name, and a third that changes no field a row shows emits nothing, with no notification sent by the test`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("Fixture")
        val main = StandardTestDispatcher(testScheduler)
        val environment = environment(transport, main)
        val model = CharactersModel(environment)
        val seen = ArrayList<Screen>()
        backgroundScope.launch(main) { model.screen.collect { seen += it } }
        runCurrent()
        transport.held.single().respond(response)
        runCurrent()

        model.refetch()
        runCurrent()
        transport.held.single().respond(renamed)
        runCurrent()
        assertEquals("Rick Prime", rows(renamed).names.first())
        assertEquals(listOf(Screen.Loading, rows(response), rows(renamed)), seen)

        model.refetch()
        runCurrent()
        transport.held.single().respond(buried)
        runCurrent()
        val status = environment.store.existing("Character:1")?.peek(Registry.slot(Registry.type("Character"), "status"))
        assertEquals(Value.String("Dead"), status, "the third response changed the store")
        assertEquals(listOf(Screen.Loading, rows(response), rows(renamed)), seen, "and no field a row shows")
        model.close()
        environment.end()
    }

    @Test
    fun `the model's hold keeps its records through a collection, and releasing it lets them go`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("Fixture")
        val main = StandardTestDispatcher(testScheduler)
        val environment = environment(transport, main)
        val store = environment.store
        val model = CharactersModel(environment)
        runCurrent()
        transport.held.single().respond(response)
        runCurrent()
        assertEquals(0, store.collect(), "nothing goes while the model holds the handle")
        assertNotNull(store.existing("Character:1"))

        model.close()
        runCurrent()
        assertNull(store.existing("Character:1"), "the pass the release scheduled collected the records")
        assertEquals(3, store.count, "the three roots are all the store holds")
        environment.end()
    }
}
