package baton

import baton.spec.TestHeaderQuery
import baton.testing.RecordedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * What `docs/recipes/outside-views.md` says of code that is not a
 * composable: a fetch commits and returns nothing, a `STORE_ONLY` handle
 * reads what the store holds without a request, and a hold is what keeps it.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class OutsideViewsTests {
    /** Answers a header lookup with the fixture for its id. */
    private fun transport() = RecordedTransport { request ->
        Spec.bytes("tests/character-header-${(request.variables["id"] as Variable.String).value}.json")
    }

    private fun TestScope.environment(transport: Transport, store: Store = Store()): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, store, dispatcher, dispatcher)
    }

    @Test
    fun `a fetch then a store-only handle reads the response with one request`() = runTest {
        val transport = transport()
        val environment = environment(transport)

        environment.fetch(TestHeaderQuery(id = "5"))
        val handle = environment.handle(TestHeaderQuery(id = "5"), FetchPolicy.STORE_ONLY)
        val ready = assertIs<Phase.Ready<TestHeaderQuery.Data>>(handle.phase, "the fetched data from the store")
        assertEquals("Jerry Smith", ready.data.character?.testHeader?.name)
        assertEquals(1, transport.requestCount, "the store-only handle sent nothing of its own")
        environment.end()
    }

    @Test
    fun `a store-only handle fails with missing data and sends nothing when the store cannot answer`() = runTest {
        val transport = transport()
        val environment = environment(transport)

        val handle = environment.handle(TestHeaderQuery(id = "5"), FetchPolicy.STORE_ONLY)
        assertIs<MissingDataError>(assertIs<Phase.Failed>(handle.phase).error)
        assertEquals(0, transport.requestCount)
        environment.end()
    }

    @Test
    fun `a fetched operation nothing holds is collected once the release buffer lets it go, and a held one stays`() = runTest {
        val environment = environment(transport(), Store(releaseBufferSize = 0))
        val store = environment.store

        val kept = environment.handle(TestHeaderQuery(id = "5"))
        val hold = kept.retain()
        runCurrent()
        environment.fetch(TestHeaderQuery(id = "11"))
        store.collect()

        assertNull(store.existing("Character:11"), "the fetch nothing held left with the empty buffer")
        assertNotNull(store.existing("Character:5"), "the held handle kept its records")
        val ready = assertIs<Phase.Ready<TestHeaderQuery.Data>>(kept.phase)
        assertEquals("Jerry Smith", ready.data.character?.testHeader?.name)
        hold.release()
        environment.end()
    }
}
