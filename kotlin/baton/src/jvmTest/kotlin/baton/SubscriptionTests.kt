package baton

import baton.spec.TestNoteAdded
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** A subscription's handle where the `subscriptions` script does not reach: the backoff, a refusal, a release and a missing transport's end. */
@OptIn(ExperimentalCoroutinesApi::class)
class SubscriptionTests {
    private val operation = TestNoteAdded(characterId = "1", connections = emptyList())

    private fun TestScope.environment(subscriptions: Transport?): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(ScriptedTransport(), subscriptions, Store(), dispatcher, dispatcher)
    }

    @Test
    fun `a stream that fails waits with the failure as its error, then connects again after the backoff as a resumption, and its events go on`() = runTest {
        val transport = ScriptedTransport()
        val environment = environment(transport)
        val handle = environment.subscriptionHandle(operation)
        val hold = handle.retain()
        runCurrent()
        transport.driven.single().fail(TransportError(503, "down"))
        runCurrent()
        assertIs<Stream.Waiting>(handle.stream)
        assertIs<TransportError>(handle.error)
        advanceTimeBy(2.seconds)
        runCurrent()
        assertEquals(Stream.Connecting, handle.stream)
        assertEquals(1, handle.resumptions)
        assertEquals(2, transport.requestCount, "the stream was opened again")
        transport.driven.single().send(Spec.bytes("tests/note-added-1.json"))
        runCurrent()
        assertEquals(Stream.Open, handle.stream)
        assertEquals(1, handle.events)
        assertNull(handle.error)
        hold.release()
        environment.end()
    }

    @Test
    fun `a stream the server refuses with a request error ends with that failure and is not opened again, and a retry opens it`() = runTest {
        val transport = ScriptedTransport()
        val environment = environment(transport)
        val handle = environment.subscriptionHandle(operation)
        val hold = handle.retain()
        runCurrent()
        transport.driven.single().fail(GraphQLErrors(listOf("refused")))
        runCurrent()
        assertIs<Failure.Request>(assertIs<Stream.Ended>(handle.stream).failure)
        advanceTimeBy(60.seconds)
        runCurrent()
        assertEquals(1, transport.requestCount, "a refusal is not retried by the handle")
        handle.retry()
        runCurrent()
        assertEquals(Stream.Connecting, handle.stream)
        assertEquals(2, transport.requestCount)
        hold.release()
        environment.end()
    }

    @Test
    fun `released to no holder, the stream closes and the subscription's root leaves the store at once`() = runTest {
        val transport = ScriptedTransport()
        val environment = environment(transport)
        val handle = environment.subscriptionHandle(operation)
        val hold = handle.retain()
        runCurrent()
        assertTrue(environment.store.roots.containsKey(handle.key))
        hold.release()
        runCurrent()
        assertEquals(Stream.Idle, handle.stream)
        assertTrue(transport.driven.isEmpty(), "the stream's flow ended")
        assertTrue(!environment.store.roots.containsKey(handle.key), "nothing is buffered")
        environment.end()
    }

    @Test
    fun `a stream with no subscription transport ends with that environment failure and is not opened again, and a retry fails the same way`() = runTest {
        val environment = environment(subscriptions = null)
        val handle = environment.subscriptionHandle(operation)
        val hold = handle.retain()
        runCurrent()
        assertSame(EnvironmentError.NoSubscriptionTransport, handle.error)
        val failure = assertIs<Failure.Environment>(assertIs<Stream.Ended>(handle.stream).failure)
        assertSame(EnvironmentError.NoSubscriptionTransport, failure.environmentError)
        advanceTimeBy(60.seconds)
        runCurrent()
        assertIs<Stream.Ended>(handle.stream, "an environment failure is not reconnected, however many steps pass")
        assertEquals(0, handle.resumptions)
        handle.retry()
        assertEquals(Stream.Connecting, handle.stream)
        runCurrent()
        assertSame(EnvironmentError.NoSubscriptionTransport, handle.error)
        assertIs<Failure.Environment>(assertIs<Stream.Ended>(handle.stream).failure)
        hold.release()
        environment.end()
    }

    @Test
    fun `the environment's end ends a retained stream with the environment's failure`() = runTest {
        val transport = ScriptedTransport()
        val environment = environment(transport)
        val handle = environment.subscriptionHandle(operation)
        handle.retain()
        runCurrent()
        environment.end()
        runCurrent()
        assertIs<Failure.Environment>(assertIs<Stream.Ended>(handle.stream).failure)
        assertSame(EnvironmentError.Gone, handle.error)
    }
}
