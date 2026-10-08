package baton

import baton.spec.TestHeaderQuery
import baton.spec.TestRename
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** The environment's rules the scripts do not hold, over the operations generated from `spec/sources`. */
@OptIn(ExperimentalCoroutinesApi::class)
class EnvironmentTests {
    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher. */
    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher)
    }

    @Test
    fun `a value outside every environment reads failed with the environment missing and its refetch throws it`() = runTest {
        val operation = TestHeaderQuery(id = "5")
        assertEquals(Phase.Loading, operation.phase, "a value no composable resolved reads as loading")
        operation.resolution = Resolution.NotInjected
        assertEquals(Phase.Failed(EnvironmentError.NotInjected), operation.phase)
        assertEquals(Fetch.Idle, operation.fetch)
        assertFailsWith<EnvironmentError> { operation.refetch() }
    }

    @Test
    fun `a mutation action is in flight until the server answers, and returns the data the payload committed`() = runTest {
        val transport = ScriptedTransport()
        val environment = environment(transport)
        val action = environment.action<TestRename, TestRename.Data>()
        val commit = async { action.commit(TestRename(id = "1", name = "Rick Prime")) }
        runCurrent()
        assertTrue(action.isInFlight)
        transport.held.single().respond(Spec.bytes("tests/rename-1.json"))
        val data = commit.await()
        assertFalse(action.isInFlight)
        assertEquals("Rick Prime", data.rename?.character?.name)
        environment.end()
    }

    @Test
    fun `a mutation action outside every environment throws rather than commit into a store that stands in`() = runTest {
        val action = MutationAction<TestRename, TestRename.Data>(null)
        assertFailsWith<EnvironmentError> { action.commit(TestRename(id = "1", name = "Rick Prime")) }
        assertFalse(action.isInFlight)
    }

    @Test
    fun `a preload's fetch serves the first attach, which sends nothing of its own`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val environment = environment(transport)
        val preloaded = environment.preload(TestHeaderQuery(id = "5"))
        runCurrent()
        assertEquals(1, transport.requestCount)
        transport.held.single().respond(Spec.bytes("tests/character-header-5.json"))
        runCurrent()
        val handle = environment.handle(TestHeaderQuery(id = "5"))
        assertSame(preloaded, handle, "equal values share one handle")
        assertEquals(1, transport.requestCount)
        assertIs<Phase.Ready<*>>(handle.phase)
        environment.end()
    }

    @Test
    fun `a collection keeps the numbers a retained root holds, and its lenses read through them after it`() = runTest {
        val transport = ScriptedTransport(mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json")))
        val environment = environment(transport)
        val handle = environment.handle(TestHeaderQuery(id = "5"))
        val retention = handle.retain()
        runCurrent()
        environment.store.collect()
        val data = assertIs<Phase.Ready<TestHeaderQuery.Data>>(handle.phase).data
        assertEquals("Jerry Smith", walk(data, "character.name"))
        retention.release()
        environment.end()
    }

    @Test
    fun `a collection frees the numbers nothing holds, drops the values under them, and gives the lowest out first`() {
        val store = Store()
        val query = store.root.type
        val first = store.keys.slot(query, "first(x:1)")
        store.keys.slot(query, "second(x:2)")
        store.local { batch -> store.set(store.root, first, Value.String("one"), batch) }
        store.collect()
        assertEquals(0, store.keys.count(query))
        assertEquals(Value.Missing, store.root.peek(first))
        assertEquals(first, store.keys.slot(query, "third(x:3)"))
    }

    @Test
    fun `an ended environment fails every later call with the environment gone`() = runTest {
        val environment = environment(ScriptedTransport())
        environment.end()
        assertFailsWith<EnvironmentError> { environment.fetch(TestHeaderQuery(id = "5")) }
        assertFailsWith<EnvironmentError> { environment.mutate(TestRename(id = "1", name = "Rick Prime")) }
        val handle = environment.handle(TestHeaderQuery(id = "5"))
        assertEquals(Phase.Failed(EnvironmentError.Gone), handle.phase)
        assertFailsWith<EnvironmentError> { handle.refetch() }
    }
}
