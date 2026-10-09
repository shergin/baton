package baton

import baton.spec.Slots
import baton.spec.TestHeaderQuery
import baton.spec.TestRename
import baton.testing.RecordedTransport
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

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
        val hold = handle.retain()
        runCurrent()
        environment.store.collect()
        val data = assertIs<Phase.Ready<TestHeaderQuery.Data>>(handle.phase).data
        assertEquals("Jerry Smith", walk(data, "character.name"))
        hold.release()
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
    fun `a scope kept past the collection that freed its number renders its key again rather than read another text's`() {
        val store = Store()
        val query = store.root.type
        val owner = Owner.reading(Variables(mapOf("id" to Variable.String("1"))), store)
        val key = DynamicKey(query, "unbuilt", listOf(KeyArgument("id", listOf(KeyPart.Variable("id")))))
        val first = owner.slot(key)
        store.local { batch -> store.set(store.root, first, Value.String("Rick"), batch) }
        store.collect()
        val other = store.keys.slot(query, "other")
        assertEquals(first, other, "the freed number went to the next text")
        val again = owner.slot(key)
        assertTrue(again != other, "the scope took a number of its own for its text")
        assertEquals("unbuilt(id:\"1\")", store.keys.text(again))
        assertEquals(Value.Missing, store.root.peek(again))
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

    @OptIn(DelicateCoroutinesApi::class)
    @Test
    fun `a suspending call made off the store's thread runs on it`() = runBlocking {
        val storeThread = newSingleThreadContext("store")
        try {
            val transport = ScriptedTransport(
                mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json"), "TestRename" to Spec.bytes("tests/rename-1.json")),
            )
            // A store belongs to the thread that made it; every read below is made there too.
            val environment = withContext(storeThread) { Environment(transport, null, Store(), storeThread, Dispatchers.Default) }
            val store = environment.store
            val name = Slots.Character.name

            withContext(Dispatchers.Default) { environment.fetch(TestHeaderQuery(id = "5")) }
            withContext(storeThread) { assertEquals(Value.String("Jerry Smith"), assertNotNull(store.recordsByKey()["Character:5"]).peek(name)) }

            val rename = TestRename(id = "1", name = "Rick Prime")
            withContext(Dispatchers.Default) { environment.commitPayload(rename, Payload(Spec.bytes("tests/rename-1.json"))) }
            withContext(storeThread) { assertEquals(Value.String("Rick Prime"), assertNotNull(store.recordsByKey()["Character:1"]).peek(name)) }

            val data = withContext(Dispatchers.Default) { environment.mutate(rename) }
            withContext(storeThread) { assertEquals("Rick Prime", data.rename?.character?.name) }

            withContext(Dispatchers.Default) { environment.end() }
            assertTrue(environment.ended)
            withContext(storeThread) { assertEquals(3, store.count, "the end left the three roots alone") }
        } finally {
            storeThread.close()
        }
    }

    @Test
    fun `the test transports record a request when it is sent, before anything collects its flow`() {
        val request = Request("TestHeaderQuery", OperationKind.QUERY, Document.Id("header"), Variables.none)
        val scripted = ScriptedTransport()
        scripted.hold("TestHeaderQuery")
        scripted.send(request)
        assertEquals(1, scripted.requestCount)
        assertEquals(1, scripted.held.size, "a held request waits for the test from its send")
        val recorded = RecordedTransport()
        recorded.send(request)
        assertEquals(1, recorded.requestCount)
    }
}
