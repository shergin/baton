package baton

import baton.exchange.Exchange
import baton.spec.TestFavorite_character
import baton.spec.TestHeaderQuery
import baton.spec.TestList
import baton.spec.TestSetFavorite
import baton.testing.ScriptedTransport
import com.sun.net.httpserver.HttpServer
import java.io.IOException
import java.net.InetSocketAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** The exchange of the `exchange` sample: the challenge's one replay, the bounded retry, the deadline and the mutation sent once. */
@OptIn(ExperimentalCoroutinesApi::class)
class ExchangeTests {
    private val query = Request("TestHeaderQuery", OperationKind.QUERY, Document.Text("query TestHeaderQuery { a }"), Variables.none)
    private val mutation = Request("TestSetFavorite", OperationKind.MUTATION, Document.Text("mutation TestSetFavorite { a }"), Variables.none)
    private val answer = Spec.bytes("tests/character-header-5.json")

    /**
     * The status of the transport error [task] failed with, or null when it
     * returned or failed with something else. The task holds its outcome as
     * a result, so its failure does not fail the test's scope.
     */
    private suspend fun status(task: Deferred<Result<ByteArray>>): Int? = (task.await().exceptionOrNull() as? TransportError)?.statusCode

    /** Runs what is due, then lets the virtual clock pass every backoff a `step` of 1 ms can wait. */
    private fun TestScope.settle() {
        runCurrent()
        advanceTimeBy(10.milliseconds)
        runCurrent()
    }

    /**
     * A server on the loopback interface that refuses its first request with
     * a 401 and answers every later one with the `character-header-5`
     * fixture, recording each request's `Authorization` header.
     */
    private class ChallengeServer : AutoCloseable {
        private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val authorizations = CopyOnWriteArrayList<String>()

        init {
            server.executor = Executors.newCachedThreadPool()
            server.createContext("/graphql") { exchange ->
                exchange.requestBody.readBytes()
                authorizations += exchange.requestHeaders.getFirst("Authorization").orEmpty()
                val challenged = authorizations.size == 1
                val body = if (challenged) "{\"message\":\"expired\"}".encodeToByteArray() else Spec.bytes("tests/character-header-5.json")
                exchange.responseHeaders.add("Content-Type", "application/json")
                exchange.sendResponseHeaders(if (challenged) 401 else 200, body.size.toLong())
                exchange.responseBody.use { it.write(body) }
                exchange.close()
            }
            server.start()
        }

        val url: String get() = "http://127.0.0.1:${server.address.port}/graphql"

        override fun close() {
            server.stop(0)
        }
    }

    @Test
    fun `a 401 then a success over HttpTransport is sent twice, challenged once, and the second attempt carries the token the challenge renewed`() = runBlocking {
        ChallengeServer().use { server ->
            val token = AtomicReference("stale")
            val challenges = AtomicInteger(0)
            val base = HttpTransport(server.url, credentials = { mapOf("Authorization" to "Bearer ${token.get()}") })
            val exchange = Exchange(base, step = 1.milliseconds) {
                challenges.incrementAndGet()
                token.set("renewed")
            }

            val payload = exchange.payload(query)
            assertContentEquals(answer, payload)
            assertEquals(1, challenges.get())
            assertEquals(listOf("Bearer stale", "Bearer renewed"), server.authorizations.toList())
        }
    }

    @Test
    fun `a second 401 after the replay fails the request with that 401, sent twice and challenged once`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        var challenges = 0
        val exchange = Exchange(transport, step = 1.milliseconds) { challenges += 1 }
        val task = async { runCatching { exchange.payload(query) } }
        runCurrent()

        transport.held.single().refuse(TransportError(401, "expired"))
        settle()
        transport.held.single().refuse(TransportError(401, "still expired"))
        settle()
        assertEquals(401, status(task))
        assertEquals(2, transport.requestCount)
        assertEquals(1, challenges)
    }

    @Test
    fun `a query refused with a 503 and then answered is sent twice and delivers the answer`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val exchange = Exchange(transport, step = 1.milliseconds)
        val task = async { runCatching { exchange.payload(query) } }
        runCurrent()

        transport.held.single().refuse(TransportError(503, "down"))
        settle()
        transport.held.single().respond(answer)
        settle()
        assertContentEquals(answer, task.await().getOrThrow())
        assertEquals(2, transport.requestCount)
    }

    @Test
    fun `a query refused with a 503 every time is sent as many times as attempts allows and fails with the 503`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val exchange = Exchange(transport, attempts = 3, step = 1.milliseconds)
        val task = async { runCatching { exchange.payload(query) } }
        runCurrent()

        for (count in 1..3) {
            assertEquals(count, transport.requestCount)
            transport.held.single().refuse(TransportError(503, "down $count"))
            settle()
        }
        assertEquals(503, status(task))
        assertEquals(3, transport.requestCount)
        assertTrue(transport.held.isEmpty())
    }

    @Test
    fun `a 503 whose backoff would pass the deadline fails with the 503 at once, sent once`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        // The default step of 500 ms makes the shortest wait 250 ms, past the deadline.
        val exchange = Exchange(transport, deadline = 20.milliseconds)
        val task = async { runCatching { exchange.payload(query) } }
        runCurrent()

        transport.held.single().refuse(TransportError(503, "down"))
        runCurrent()
        assertTrue(task.isCompleted, "the exchange failed without waiting")
        assertEquals(503, status(task))
        assertEquals(0, testScheduler.currentTime, "no virtual time passed in a backoff")
        assertEquals(1, transport.requestCount)
    }

    @Test
    fun `a mutation refused with a 503 is sent once and fails`() = runTest {
        val transport = ScriptedTransport()
        val exchange = Exchange(transport, step = 1.milliseconds)
        val task = async { runCatching { exchange.payload(mutation) } }
        runCurrent()

        transport.held.single().refuse(TransportError(503, "down"))
        settle()
        assertEquals(503, status(task))
        assertEquals(1, transport.requestCount)
    }

    @Test
    fun `a mutation refused with a 401 is replayed once, and a 503 on the replay fails it, sent twice`() = runTest {
        val transport = ScriptedTransport()
        var challenges = 0
        val exchange = Exchange(transport, step = 1.milliseconds) { challenges += 1 }
        val task = async { runCatching { exchange.payload(mutation) } }
        runCurrent()

        transport.held.single().refuse(TransportError(401, "expired"))
        settle()
        val replay = transport.held.single()
        assertEquals(OperationKind.MUTATION, replay.request.kind)
        replay.refuse(TransportError(503, "down"))
        settle()
        assertEquals(503, status(task))
        assertEquals(2, transport.requestCount)
        assertEquals(1, challenges)
    }

    @Test
    fun `a stream that delivered a payload and then failed yields the payload, throws the failure, and is not sent again`() = runTest {
        val transport = ScriptedTransport()
        transport.drive("TestHeaderQuery")
        val exchange = Exchange(transport, step = 1.milliseconds)
        val received = ArrayList<ByteArray>()
        val task = async {
            try {
                exchange.send(query).collect { received += it }
                null
            } catch (error: TransportError) {
                error
            }
        }
        runCurrent()

        val driven = transport.driven.single()
        driven.send(answer)
        driven.fail(TransportError(503, "the stream broke"))
        settle()
        val error = task.await()
        assertEquals(1, received.size)
        assertContentEquals(answer, received.single())
        assertEquals(503, error?.statusCode)
        assertEquals(1, transport.requestCount)
    }

    @Test
    fun `a 400 and a failure with no response are not retried, each is sent once`() = runTest {
        val refused = ScriptedTransport()
        refused.hold("TestHeaderQuery")
        val task = async { runCatching { Exchange(refused, step = 1.milliseconds).payload(query) } }
        runCurrent()
        refused.held.single().refuse(TransportError(400, "bad request"))
        settle()
        assertEquals(400, status(task))
        assertEquals(1, refused.requestCount)

        // An unscripted query fails with a status 0 and no cause: the transport made no connection to lose.
        val unscripted = ScriptedTransport()
        val unanswered = async { runCatching { Exchange(unscripted, step = 1.milliseconds).payload(query) } }
        settle()
        assertEquals(0, status(unanswered))
        assertEquals(1, unscripted.requestCount)
    }

    @Test
    fun `whether a retry mends a failure, a 5xx and a lost connection do, a 4xx, a 401, a status 0 with no cause and another error do not`() {
        assertTrue(Exchange.mends(TransportError(500, "")))
        assertTrue(Exchange.mends(TransportError(599, "")))
        assertTrue(Exchange.mends(TransportError(0, "connection lost", IOException("connection reset"))))
        assertFalse(Exchange.mends(TransportError(400, "")))
        assertFalse(Exchange.mends(TransportError(401, "")))
        assertFalse(Exchange.mends(TransportError(0, "")))
        assertFalse(Exchange.mends(GraphQLErrors(listOf("boom"))))
        assertFalse(Exchange.mends(CancellationException("cancelled")))
        assertFalse(Exchange.mends(IllegalStateException("malformed")))
    }

    @Test
    fun `cancelling the consumer of the exchange's flow while the base holds the request ends the base's flow, so held is empty`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val exchange = Exchange(transport, step = 1.milliseconds)
        val job = launch { exchange.send(query).collect {} }
        runCurrent()
        assertEquals(1, transport.held.size)

        job.cancel()
        runCurrent()
        assertTrue(transport.held.isEmpty())
        assertEquals(1, transport.requestCount)
    }

    @Test
    fun `an environment over an exchange reads a query ready after its first answer was a 503, sent twice`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val dispatcher = StandardTestDispatcher(testScheduler)
        val environment = Environment(Exchange(transport, step = 1.milliseconds), null, Store(), dispatcher, dispatcher)
        val handle = environment.handle(TestHeaderQuery(id = "5"))
        val hold = handle.retain()
        runCurrent()

        transport.held.single().refuse(TransportError(503, "down"))
        settle()
        transport.held.single().respond(answer)
        settle()
        val ready = assertIs<Phase.Ready<TestHeaderQuery.Data>>(handle.phase)
        assertEquals("Jerry Smith", ready.data.character?.testHeader?.name)
        assertEquals(2, transport.requestCount)
        hold.release()
        environment.end()
    }

    @Test
    fun `a held mutation's optimistic layer stays applied while a query beside it is retried after a 503, and commits when answered`() = runTest {
        val transport = ScriptedTransport()
        transport.hold("TestHeaderQuery")
        val store = Store()
        val list = TestList(page = 1)
        store.commit(Ingest.normalize(Spec.bytes("rickandmorty/characters-page-1.json"), store.resolve(TestList.plan, list.variables), Store.ROOT_KEY))
        val dispatcher = StandardTestDispatcher(testScheduler)
        val environment = Environment(Exchange(transport, step = 1.milliseconds), null, store, dispatcher, dispatcher)
        val record = assertNotNull(store.existing("Character:1"))
        val rick = TestFavorite_character(Anchor(record, Owner.reading(Variables.none, store)))
        val optimistic = TestSetFavorite.OptimisticResponse(
            TestSetFavorite.OptimisticResponse.SetFavorite(TestSetFavorite.OptimisticResponse.SetFavorite.Character(id = "1", favorite = true)),
        )
        val favorite = async { environment.mutate(TestSetFavorite(id = "1", favorite = true), optimistic = optimistic.payload) }
        runCurrent()
        assertEquals(true, rick.favorite)
        assertEquals(1, transport.held.size)

        val fetch = async { environment.fetch(TestHeaderQuery(id = "5")) }
        runCurrent()
        assertEquals(2, transport.requestCount)
        transport.held.single { it.request.kind == OperationKind.QUERY }.refuse(TransportError(503, "down"))
        settle()
        assertEquals(3, transport.requestCount, "the query was sent again")
        assertEquals(2, transport.held.size)
        assertEquals(true, rick.favorite, "the retry did not disturb the layer")
        assertEquals(1, store.optimisticLayers.size)

        transport.held.single { it.request.kind == OperationKind.QUERY }.respond(answer)
        settle()
        fetch.await()
        assertEquals(true, rick.favorite)
        assertEquals(1, store.optimisticLayers.size)

        transport.held.single { it.request.kind == OperationKind.MUTATION }.respond(Spec.bytes("tests/set-favorite-1.json"))
        settle()
        val data = favorite.await()
        assertEquals(true, data.setFavorite?.character?.favorite)
        assertTrue(store.optimisticLayers.isEmpty())
        assertEquals(1, transport.requests(OperationKind.MUTATION).size)
        assertEquals(2, transport.requests(OperationKind.QUERY).size)
        environment.end()
    }
}
