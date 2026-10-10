package baton

import baton.spec.TestNoteAdded
import baton.testing.SocketServer
import baton.testing.wait
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/** The socket transport against a `graphql-transport-ws` server on the loopback interface. */
class WebSocketTransportTests {
    private val servers = ArrayList<SocketServer>()

    private fun server(acknowledges: Boolean = true): SocketServer = SocketServer(acknowledges).also(servers::add)

    @AfterTest
    fun stopServers() {
        servers.forEach { it.stop() }
    }

    private val noteAdded = TestNoteAdded(characterId = "1", connections = emptyList())

    private val request = Request(TestNoteAdded.name, OperationKind.SUBSCRIPTION, TestNoteAdded.document, noteAdded.variables)

    /** Waits on the server's threads, failing with [message] after the default timeout. */
    private suspend fun until(message: String, condition: () -> Boolean) {
        assertTrue(wait({ condition() }), message)
    }

    @Test
    fun `a subscription opens one socket offering the protocol, with the credentials and the connection's params, and subscribes the encoding's JSON`() = runBlocking {
        val server = server()
        val socket = GraphQLTransportWebSocket(
            server.url,
            credentials = { mapOf("Authorization" to "Bearer token") },
            connectionParams = Variable.Object(mapOf("token" to Variable.String("secret"))),
        )
        val reader = launch(Dispatchers.Default) { socket.send(request).collect {} }
        until("the subscription was sent") { server.count("subscribe") == 1 }
        assertEquals(listOf("graphql-transport-ws"), server.offeredProtocols)
        assertEquals(listOf("Bearer token"), server.authorizations)
        assertEquals(listOf("{\"token\":\"secret\"}"), server.payloads("connection_init"))
        @Suppress("UNCHECKED_CAST")
        val payload = Json.parse(server.payloads("subscribe").single()) as Map<String, Any?>
        assertEquals("TestNoteAdded", payload["operationName"])
        assertEquals((TestNoteAdded.document as Document.Text).text, payload["query"])
        assertEquals(mapOf("characterId" to "1", "connections" to emptyList<Any?>()), payload["variables"])
        reader.cancel()
        until("the socket closed") { server.closed == 1 }
    }

    @Test
    fun `another encoding writes the subscribe payload`() = runBlocking {
        val server = server()
        val byId = Encoding { sent -> "{\"id\":${Variable.quote((sent.document as? Document.Id)?.id ?: "")}}".encodeToByteArray() }
        val socket = GraphQLTransportWebSocket(server.url, encoding = byId)
        val persisted = Request(TestNoteAdded.name, OperationKind.SUBSCRIPTION, Document.Id("0a1b2c"), noteAdded.variables)
        val reader = launch(Dispatchers.Default) { socket.send(persisted).collect {} }
        until("the subscription was sent") { server.count("subscribe") == 1 }
        assertEquals(listOf("{\"id\":\"0a1b2c\"}"), server.payloads("subscribe"))
        reader.cancel()
    }

    @Test
    fun `a query over the socket answers with the one payload the server completes after`() = runBlocking {
        val server = server()
        val socket = GraphQLTransportWebSocket(server.url)
        val query = Request("Stub", OperationKind.QUERY, Document.Text("query Stub { a }"), Variables.none)
        // The whole flow, not its first payload: a reader that stops at the first payload may go away before the
        // server's `complete` is read, and then rightly completes the stream itself. The flow ends only when the
        // transport has handled the server's `complete`, so what the client sent after it is settled.
        val answer = async(Dispatchers.Default) { socket.send(query).toList() }
        until("the query was sent") { server.count("subscribe") == 1 }
        val id = server.ids("subscribe").single()
        server.send("{\"id\":\"$id\",\"type\":\"next\",\"payload\":{\"data\":{\"a\":1}}}")
        server.send("{\"id\":\"$id\",\"type\":\"complete\"}")
        assertEquals(listOf("{\"data\":{\"a\":1}}"), answer.await().map { it.decodeToString() })
        until("the socket closed once nothing was on it") { server.closed == 1 }
        assertEquals(0, server.count("complete"), "a stream the server completed owes it nothing")
    }

    @Test
    fun `an error frame ends its stream with its GraphQL errors and closes the unused socket, and a stream whose reader goes away is completed by its id`() = runBlocking {
        val server = server()
        val socket = GraphQLTransportWebSocket(server.url)
        val failing = async(Dispatchers.Default) { runCatching { socket.send(request).collect {} }.exceptionOrNull() }
        until("the subscription was sent") { server.count("subscribe") == 1 }
        val id = server.ids("subscribe").single()
        server.send("{\"id\":\"$id\",\"type\":\"error\",\"payload\":[{\"message\":\"bad subscription\",\"path\":[\"noteAdded\"],\"extensions\":{\"code\":\"FORBIDDEN\"}}]}")
        val errors = assertIs<GraphQLErrors>(failing.await())
        assertEquals(listOf("bad subscription"), errors.messages)
        assertEquals(listOf("noteAdded"), errors.errors.map { it.path })
        assertEquals(Variable.Object(mapOf("code" to Variable.String("FORBIDDEN"))), errors.errors.single().extensions)
        until("the socket closed") { server.closed == 1 }

        val reader = launch(Dispatchers.Default) { socket.send(request).collect {} }
        until("a second socket subscribed") { server.count("subscribe") == 2 }
        assertEquals(2, server.opened)
        reader.cancel()
        until("the stream was completed") { server.count("complete") == 1 }
        assertEquals(listOf(server.ids("subscribe").last()), server.ids("complete"))
        until("the second socket closed") { server.closed == 2 }
    }

    @Test
    fun `two subscriptions sent at once on a fresh socket whose credentials take a while share one connection, each under its own id, and each receives its events`() = runBlocking {
        val server = server()
        val socket = GraphQLTransportWebSocket(server.url, credentials = {
            // A suspension in the read, as a token refresh would make, during which the other request reaches the socket.
            delay(20.milliseconds)
            mapOf("Authorization" to "Bearer token")
        })
        val received = CopyOnWriteArrayList<String>()
        val readers = listOf("first", "second").map { reader ->
            launch(Dispatchers.Default) { socket.send(request).collect { received += reader } }
        }
        until("both subscribed") { server.count("subscribe") == 2 }
        assertEquals(1, server.count("connection_init"), "one connection serves both")
        val ids = server.ids("subscribe")
        assertEquals(2, ids.toSet().size, "each stream subscribes under its own id")
        for (id in ids) server.send("{\"id\":\"$id\",\"type\":\"next\",\"payload\":{\"data\":{\"noteAdded\":null}}}")
        until("each received its event") { received.sorted() == listOf("first", "second") }
        assertEquals(1, server.opened)
        readers.forEach { it.cancel() }
        until("the socket closed after both left") { server.closed == 1 }
    }

    @Test
    fun `equal subscriptions on one socket are separate, and the server's end of one leaves the other open`() = runBlocking {
        val server = server()
        val socket = GraphQLTransportWebSocket(server.url)
        val first = launch(Dispatchers.Default) { socket.send(request).collect {} }
        until("the first subscribed") { server.count("subscribe") == 1 }
        val received = CopyOnWriteArrayList<String>()
        val second = launch(Dispatchers.Default) { socket.send(request).collect { received += it.decodeToString() } }
        until("the second subscribed") { server.count("subscribe") == 2 }
        val (firstId, secondId) = server.ids("subscribe")
        server.send("{\"id\":\"$firstId\",\"type\":\"complete\"}")
        first.join()
        // A ping answered after the completion shows the client sent no `complete` of its own.
        server.send("{\"type\":\"ping\"}")
        until("the ping was answered") { server.count("pong") == 1 }
        assertEquals(0, server.count("complete"))
        server.send("{\"id\":\"$secondId\",\"type\":\"next\",\"payload\":{\"data\":{\"noteAdded\":null}}}")
        until("the other received its event") { received == listOf("{\"data\":{\"noteAdded\":null}}") }
        second.cancel()
        until("the other was completed by its id") { server.ids("complete") == listOf(secondId) }
        until("the socket closed") { server.closed == 1 }
    }

    @Test
    fun `a subscription whose reader goes away before the acknowledgement closes the socket it opened and subscribes nothing`() = runBlocking {
        val server = server(acknowledges = false)
        val socket = GraphQLTransportWebSocket(server.url)
        val leaving = launch(Dispatchers.Default) { socket.send(request).collect {} }
        until("the connection was initialised") { server.count("connection_init") == 1 }
        leaving.cancel()
        until("the socket closed") { server.closed == 1 }
        assertEquals(0, server.count("subscribe"))
    }

    @Test
    fun `a subscription that goes away beside another waiting for the same acknowledgement leaves the socket to it`() = runBlocking {
        val server = server(acknowledges = false)
        val socket = GraphQLTransportWebSocket(server.url)
        val received = CopyOnWriteArrayList<ByteArray>()
        val staying = launch(Dispatchers.Default) { socket.send(request).collect { received += it } }
        until("the connection was initialised") { server.count("connection_init") == 1 }
        val leaving = launch(Dispatchers.Default) { socket.send(request).collect {} }
        delay(20.milliseconds)
        leaving.cancel()
        leaving.join()
        server.acknowledge()
        until("the one that stayed subscribed") { server.count("subscribe") == 1 }
        server.send("{\"id\":\"${server.ids("subscribe").single()}\",\"type\":\"next\",\"payload\":{\"data\":{\"noteAdded\":null}}}")
        until("it received its event") { received.size == 1 }
        assertEquals(1, server.count("subscribe"), "the one that went away subscribed nothing")
        assertEquals(0, server.closed)
        staying.cancel()
        until("the socket closed") { server.closed == 1 }
    }

    @Test
    fun `a socket the server closes fails every stream on it with status 0, and the next request opens another`() = runBlocking {
        val server = server()
        val socket = GraphQLTransportWebSocket(server.url)
        val failing = async(Dispatchers.Default) { runCatching { socket.send(request).collect {} }.exceptionOrNull() }
        until("the subscription was sent") { server.count("subscribe") == 1 }
        server.hangUp()
        assertEquals(0, assertIs<TransportError>(failing.await()).statusCode)
        val reader = launch(Dispatchers.Default) { socket.send(request).collect {} }
        until("a new socket subscribed") { server.count("subscribe") == 2 }
        assertEquals(2, server.opened)
        reader.cancel()
    }

    @Test
    fun `a socket that cannot be opened fails the stream with status 0`() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }
        val socket = GraphQLTransportWebSocket("ws://127.0.0.1:$port/graphql")
        val failure = assertFailsWith<TransportError> { socket.send(request).collect {} }
        assertEquals(0, failure.statusCode)
    }

    /**
     * An environment on the calling thread, which owns its store, reading
     * responses off it. A test ends it in a `finally`: once `runBlocking`
     * returns, its event loop hands what is dispatched to it to the default
     * executor, where the write observer of an environment left running
     * would send the apply notifications after every snapshot write the
     * later tests make.
     */
    private fun CoroutineScope.environment(subscriptions: Transport): Environment =
        Environment(HttpTransport("http://127.0.0.1:1/unused"), subscriptions, Store(), coroutineContext[ContinuationInterceptor] as CoroutineDispatcher, Dispatchers.Default)

    @Test
    fun `an environment's subscription over the socket commits each event, and an error frame ends it with the request failure without reconnecting`() = runBlocking {
        val server = server()
        val environment = environment(GraphQLTransportWebSocket(server.url))
        try {
            val handle = environment.subscriptionHandle(noteAdded)
            val hold = handle.retain()
            until("the subscription was sent") { server.count("subscribe") == 1 }
            val id = server.ids("subscribe").single()
            server.send("{\"id\":\"$id\",\"type\":\"next\",\"payload\":${Spec.text("tests/note-added-1.json").trim()}}")
            until("the event was committed") { handle.events == 1 }
            assertEquals(Stream.Open, handle.stream)
            server.send("{\"id\":\"$id\",\"type\":\"error\",\"payload\":[{\"message\":\"bad subscription\"}]}")
            until("the stream ended") { handle.stream is Stream.Ended }
            val failure = assertIs<Failure.Request>(assertIs<Stream.Ended>(handle.stream).failure)
            assertEquals(listOf("bad subscription"), failure.errors.messages)
            assertEquals(0, handle.resumptions)
            assertEquals(1, server.count("subscribe"))
            hold.release()
        } finally {
            environment.end()
        }
    }
}
