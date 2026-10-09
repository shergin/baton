package baton.okhttp

import baton.Document
import baton.GraphQLErrors
import baton.GraphQLTransportWebSocket
import baton.OperationKind
import baton.Request
import baton.TransportError
import baton.Variable
import baton.Variables
import baton.testing.SocketServer
import baton.testing.wait
import java.net.ServerSocket
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient

/**
 * The socket transport over OkHttp's WebSocket against the
 * `graphql-transport-ws` server double on the loopback interface. The
 * transport's multiplexing is proven by the runtime's tests; these prove the
 * client it speaks through. `androidDeviceTest` holds the same tests on a
 * device.
 */
class OkHttpWebSocketTests {
    private val servers = ArrayList<SocketServer>()

    private fun server(): SocketServer = SocketServer().also(servers::add)

    /** The app's client, with short timeouts, so a test that fails fails quickly. */
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(2, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .build()

    @AfterTest
    fun stopServersAndClient() {
        servers.forEach { it.stop() }
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }

    /** The socket transport to [url], opening its sockets through this test's OkHttp client. */
    private fun transport(
        url: String,
        credentials: suspend () -> Map<String, String> = { emptyMap() },
        connectionParams: Variable? = null,
    ): GraphQLTransportWebSocket =
        GraphQLTransportWebSocket(url, credentials = credentials, connectionParams = connectionParams, client = OkHttpWebSocketClient(client))

    /** Waits on the server's threads, failing with [message] after the default timeout. */
    private suspend fun until(message: String, condition: () -> Boolean) {
        assertTrue(wait({ condition() }), message)
    }

    private val subscription = Request(
        "NoteAdded",
        OperationKind.SUBSCRIPTION,
        Document.Text("subscription NoteAdded(\$characterId: ID!) { noteAdded(characterId: \$characterId) { id } }"),
        Variables.of("characterId" to Variable.String("1")),
    )

    private val query = Request("Stub", OperationKind.QUERY, Document.Text("query Stub { a }"), Variables.none)

    @Test
    fun `a subscription opens one socket offering the protocol, with the credentials and the connection's params, and subscribes the encoding's JSON`() = runBlocking {
        val server = server()
        val socket = transport(
            server.url,
            credentials = { mapOf("Authorization" to "Bearer token") },
            connectionParams = Variable.Object(mapOf("token" to Variable.String("secret"))),
        )
        val reader = launch(Dispatchers.Default) { socket.send(subscription).collect {} }
        until("the subscription was sent") { server.count("subscribe") == 1 }
        assertEquals(1, server.opened)
        assertEquals(listOf("graphql-transport-ws"), server.offeredProtocols)
        assertEquals(listOf("Bearer token"), server.authorizations)
        assertEquals(listOf("{\"token\":\"secret\"}"), server.payloads("connection_init"))
        assertEquals(listOf(subscription.body.decodeToString()), server.payloads("subscribe"))
        reader.cancel()
        // The `complete` is sent before the close that follows it.
        until("the stream was completed by its id") { server.ids("complete") == server.ids("subscribe") }
        until("the socket closed") { server.closed == 1 }
    }

    @Test
    fun `a query over the socket answers with the one payload the server completes after, and the socket closes once nothing is on it`() = runBlocking {
        val server = server()
        val socket = transport(server.url)
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
    fun `an error frame ends its stream with its GraphQL errors`() = runBlocking {
        val server = server()
        val socket = transport(server.url)
        val failing = async(Dispatchers.Default) { runCatching { socket.send(subscription).collect {} }.exceptionOrNull() }
        until("the subscription was sent") { server.count("subscribe") == 1 }
        val id = server.ids("subscribe").single()
        server.send("{\"id\":\"$id\",\"type\":\"error\",\"payload\":[{\"message\":\"bad subscription\",\"path\":[\"noteAdded\"],\"extensions\":{\"code\":\"FORBIDDEN\"}}]}")
        val errors = assertIs<GraphQLErrors>(failing.await())
        assertEquals(listOf("bad subscription"), errors.messages)
        assertEquals(listOf("noteAdded"), errors.errors.map { it.path })
        assertEquals(Variable.Object(mapOf("code" to Variable.String("FORBIDDEN"))), errors.errors.single().extensions)
        until("the socket closed") { server.closed == 1 }
    }

    @Test
    fun `a socket the server closes fails every stream on it with status 0, and the next request opens another`() = runBlocking {
        val server = server()
        val socket = transport(server.url)
        val failing = List(2) { async(Dispatchers.Default) { runCatching { socket.send(subscription).collect {} }.exceptionOrNull() } }
        until("both streams subscribed") { server.count("subscribe") == 2 }
        assertEquals(1, server.opened, "both streams are on one socket")
        server.hangUp()
        for (stream in failing) assertEquals(0, assertIs<TransportError>(stream.await()).statusCode)
        val reader = launch(Dispatchers.Default) { socket.send(subscription).collect {} }
        until("a new socket subscribed") { server.count("subscribe") == 3 }
        assertEquals(2, server.opened)
        reader.cancel()
        until("both sockets closed") { server.closed == 2 }
    }

    @Test
    fun `a socket that cannot be opened fails the stream with status 0`() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }
        val socket = transport("ws://127.0.0.1:$port/graphql")
        val failure = assertFailsWith<TransportError> { socket.send(subscription).collect {} }
        assertEquals(0, failure.statusCode)
    }
}
