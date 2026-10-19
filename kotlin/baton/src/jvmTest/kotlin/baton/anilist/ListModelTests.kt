package baton.anilist

import baton.Environment
import baton.Hold
import baton.Phase
import baton.Store
import baton.Transport
import baton.Variable
import baton.Spec
import baton.testing.RecordedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** The model of the derived-state recipe's whole operation, over the list recorded under `spec/anilist/`, as `ListModelTests.swift` proves it. */
@OptIn(ExperimentalCoroutinesApi::class)
class ListModelTests {
    private fun recorded(name: String): ByteArray = Spec.bytes("anilist/$name")

    private fun aniListTransport(): RecordedTransport = RecordedTransport { request ->
        when {
            request.operationName == SaveEntryMutation.name -> recorded("save-entry-991-progress.json")
            request.operationName != ListQuery.name -> null
            else -> (request.variables["chunk"] as? Variable.Int)?.value?.takeIf { it <= 2L }?.let { recorded("list-anime-chunk-$it.json") }
        }
    }

    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher).also { it.log = null }
    }

    /** Both chunks fetched into the store and held as a screen holds them. */
    private suspend fun TestScope.filled(environment: Environment): List<Hold> = (1..2).map { chunk ->
        val handle = environment.handle(ListQuery(userId = 0, mediaType = MediaType.ANIME, chunk = chunk))
        val hold = handle.retain()
        runCurrent()
        handle.settle()
        assertIs<Phase.Ready<ListQuery.Data>>(handle.phase)
        hold
    }

    @Test
    fun `a model made over a store that holds every chunk has every entry in the call that makes it, with no request`() = runTest {
        val transport = aniListTransport()
        val environment = environment(transport)
        val holds = filled(environment)
        val sent = transport.requests.size

        val model = ListModel(environment, backgroundScope, userId = 0, chunks = 2)
        assertEquals(1_000, model.entries.value.size)
        assertEquals(Entry(1, MediaListStatus.COMPLETED, 12, "009-1", null), model.entries.value.first())
        assertEquals(Entry(991, MediaListStatus.PAUSED, 248, "ONE PIECE", 1_798_985_760), model.entries.value.first { it.id == 991 })
        runCurrent()
        assertEquals(sent, transport.requests.size)
        model.close()
        holds.forEach { it.release() }
        environment.end()
    }

    @Test
    fun `the flows' first readings change nothing, and a save in one chunk changes the one entry it saved`() = runTest {
        val environment = environment(aniListTransport())
        val holds = filled(environment)
        val model = ListModel(environment, backgroundScope, userId = 0, chunks = 2)
        val before = model.entries.value
        val seen = ArrayList<List<Entry>>()
        backgroundScope.launch { model.entries.collect { seen.add(it) } }
        runCurrent()
        assertEquals(listOf(before), seen, "a flow's first reading is equal to the untracked one")

        val saved = async { environment.mutate(SaveEntryMutation(id = 991, progress = 249)) }
        runCurrent()
        saved.await()
        runCurrent()
        assertEquals(2, seen.size)
        assertEquals(listOf(991), before.zip(model.entries.value).filter { (old, new) -> old != new }.map { it.first.id })
        assertEquals(249, model.entries.value.first { it.id == 991 }.progress)
        model.close()
        holds.forEach { it.release() }
        environment.end()
    }
}
