package baton.okhttp

import baton.Document
import baton.Encoding
import baton.GraphQLErrors
import baton.OperationKind
import baton.Request
import baton.TransportError
import baton.Variable
import baton.Variables
import baton.testing.wait
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.Call
import okhttp3.OkHttpClient

/**
 * The HTTP transport over OkHttp against a server on the loopback interface:
 * what it sends, and that it reads a response as the runtime's
 * `HttpTransport` reads one. `androidDeviceTest` holds the same tests on a
 * device, against a server of its own.
 */
class OkHttpTransportTests {
    /** What the server received of one request: its method, its headers by lowercased name, and its body. */
    class Received(val method: String, val headers: Map<String, String>, val body: String)

    /** A server on an ephemeral port that answers every request through [respond], keeping what it received. */
    class LocalServer(private val respond: (HttpExchange) -> Unit) {
        private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val received = CopyOnWriteArrayList<Received>()

        init {
            server.executor = Executors.newCachedThreadPool()
            server.createContext("/graphql") { exchange ->
                val headers = exchange.requestHeaders.entries.associate { it.key.lowercase() to it.value.joinToString(",") }
                received += Received(exchange.requestMethod, headers, exchange.requestBody.readBytes().decodeToString())
                try {
                    respond(exchange)
                } catch (_: IOException) {
                    // The client went away.
                } finally {
                    exchange.close()
                }
            }
            server.start()
        }

        val url: String get() = "http://127.0.0.1:${server.address.port}/graphql"

        fun stop() {
            server.stop(0)
        }
    }

    private val servers = ArrayList<LocalServer>()

    private fun serve(respond: (HttpExchange) -> Unit): LocalServer = LocalServer(respond).also(servers::add)

    /** Every call the client made, as OkHttp holds it, so a test can ask whether one was cancelled. */
    private val calls = CopyOnWriteArrayList<Call>()

    /** The app's client: short timeouts, so a test that fails fails quickly, and an interceptor that keeps each call. */
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(2, TimeUnit.SECONDS)
        .readTimeout(5, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            calls += chain.call()
            chain.proceed(chain.request())
        }
        .build()

    @AfterTest
    fun stopServersAndClient() {
        servers.forEach { it.stop() }
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }

    /** Answers with [status] and [contentType], then hands the body to [writing]; the response ends when it returns. */
    private fun stream(exchange: HttpExchange, status: Int, contentType: String, writing: (OutputStream) -> Unit) {
        exchange.responseHeaders.add("Content-Type", contentType)
        exchange.sendResponseHeaders(status, 0)
        exchange.responseBody.use(writing)
    }

    /** Answers with [status], [contentType] and [body]. */
    private fun answer(exchange: HttpExchange, status: Int, contentType: String, body: String) {
        stream(exchange, status, contentType) { it.writeInChunks(body) }
    }

    /** Writes [text] seven bytes at a time, each flushed, so lines and parts straddle the client's reads. */
    private fun OutputStream.writeInChunks(text: String) {
        val bytes = text.encodeToByteArray()
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + 7, bytes.size)
            write(bytes, offset, end - offset)
            flush()
            offset = end
        }
    }

    /** Waits on the server's threads, failing with [message] after the default timeout. */
    private suspend fun until(message: String, condition: () -> Boolean) {
        assertTrue(wait({ condition() }), message)
    }

    private val query = Request("Stub", OperationKind.QUERY, Document.Text("query Stub { a }"), Variables.none)

    private val deferred = Request("Deferred", OperationKind.QUERY, Document.Text("query Deferred { a ... @defer { b } }"), Variables.none, incremental = true)

    private val subscription = Request("Ticks", OperationKind.SUBSCRIPTION, Document.Text("subscription Ticks { tick }"), Variables.none)

    @Test
    fun `a query posts the encoding's JSON with the JSON content type, the fixed headers and the credentials, accepting a GraphQL response, and receives the one payload`() = runBlocking {
        val server = serve { answer(it, 200, "application/json", "{\"data\":{\"a\":1}}") }
        val transport = OkHttpTransport(client, server.url, headers = mapOf("X-Client" to "baton"), credentials = { mapOf("Authorization" to "Bearer token") })
        val payloads = transport.send(query).toList()
        assertEquals(listOf("{\"data\":{\"a\":1}}"), payloads.map { it.decodeToString() })
        val received = server.received.single()
        assertEquals("POST", received.method)
        assertEquals(query.body.decodeToString(), received.body)
        assertEquals("application/json", received.headers["content-type"])
        assertEquals("application/graphql-response+json, application/json", received.headers["accept"])
        assertEquals("baton", received.headers["x-client"])
        assertEquals("Bearer token", received.headers["authorization"])
    }

    @Test
    fun `another encoding writes the body`() = runBlocking {
        val server = serve { answer(it, 200, "application/json", "{\"data\":{}}") }
        val byId = Encoding { sent -> "{\"id\":${Variable.quote((sent.document as? Document.Id)?.id ?: "")}}".encodeToByteArray() }
        val persisted = Request("Stub", OperationKind.QUERY, Document.Id("0a1b2c"), Variables.none)
        OkHttpTransport(client, server.url, encoding = byId).send(persisted).toList()
        assertEquals("{\"id\":\"0a1b2c\"}", server.received.single().body)
    }

    @Test
    fun `the credentials are read for every attempt, so a rotated token reaches the next request, and replace a fixed header of the same name`() = runBlocking {
        val server = serve { answer(it, 200, "application/json", "{\"data\":{}}") }
        val reads = AtomicInteger(0)
        val transport = OkHttpTransport(client, server.url, headers = mapOf("Authorization" to "fixed"), credentials = { mapOf("Authorization" to "Bearer ${reads.incrementAndGet()}") })
        val sent = transport.send(query)
        sent.toList()
        sent.toList()
        assertEquals(listOf("Bearer 1", "Bearer 2"), server.received.map { it.headers["authorization"] })
    }

    @Test
    fun `a deferred operation asks for multipart and receives each part as it arrives`() = runBlocking {
        val parts = listOf("{\"data\":{\"a\":1},\"hasNext\":true}", "{\"incremental\":[{\"data\":{\"b\":2},\"path\":[]}],\"hasNext\":false}")
        val firstArrived = CountDownLatch(1)
        val server = serve { exchange ->
            stream(exchange, 200, "multipart/mixed; boundary=\"-\"; deferSpec=20220824") { output ->
                output.writeInChunks("\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n${parts[0]}\r\n---\r\n")
                // The second part is written only once the client has the first, so the first cannot have come with it.
                if (!firstArrived.await(10, TimeUnit.SECONDS)) return@stream
                output.writeInChunks("Content-Type: application/json; charset=utf-8\r\n\r\n${parts[1]}\r\n-----\r\n")
            }
        }
        val received = ArrayList<String>()
        OkHttpTransport(client, server.url).send(deferred).collect { part ->
            received += part.decodeToString()
            firstArrived.countDown()
        }
        assertEquals(parts, received)
        assertEquals("multipart/mixed; deferSpec=20220824, application/graphql-response+json, application/json", server.received.single().headers["accept"])
    }

    @Test
    fun `a subscription asks for an event stream and receives each event as it arrives`() = runBlocking {
        val events = listOf("{\"data\":{\"tick\":1}}", "{\"data\":{\"tick\":2}}")
        val firstArrived = CountDownLatch(1)
        val server = serve { exchange ->
            stream(exchange, 200, "text/event-stream") { output ->
                output.writeInChunks(": connected\n\nevent: next\ndata: ${events[0]}\n\n")
                // The second event is written only once the client has the first, so the first cannot have come with it.
                if (!firstArrived.await(10, TimeUnit.SECONDS)) return@stream
                output.writeInChunks("event: next\ndata: ${events[1]}\n\nevent: complete\ndata:\n\n")
            }
        }
        val received = ArrayList<String>()
        OkHttpTransport(client, server.url).send(subscription).collect { event ->
            received += event.decodeToString()
            firstArrived.countDown()
        }
        assertEquals(events, received)
        assertEquals("text/event-stream, application/graphql-response+json, application/json", server.received.single().headers["accept"])
    }

    @Test
    fun `a response outside 2xx fails with a transport error of its status and its body`() = runBlocking {
        val server = serve { answer(it, 500, "text/plain", "down for maintenance") }
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, server.url).send(query).toList() }
        assertEquals(500, failure.statusCode)
        assertEquals("down for maintenance", failure.body)
    }

    @Test
    fun `a request error answered as a GraphQL response fails with its GraphQL errors`() = runBlocking {
        val refusal = "{\"errors\":[{\"message\":\"Cannot query field \\\"nope\\\" on type \\\"Query\\\".\",\"extensions\":{\"code\":\"GRAPHQL_VALIDATION_FAILED\"}}]}"
        val server = serve { answer(it, 400, "application/graphql-response+json; charset=utf-8", refusal) }
        val errors = assertFailsWith<GraphQLErrors> { OkHttpTransport(client, server.url).send(query).toList() }
        assertEquals(listOf("Cannot query field \"nope\" on type \"Query\"."), errors.messages)
        assertEquals(Variable.Object(mapOf("code" to Variable.String("GRAPHQL_VALIDATION_FAILED"))), errors.errors.single().extensions)
    }

    @Test
    fun `a request error answered as plain JSON stays a transport error of its status and its body`() = runBlocking {
        val refusal = "{\"errors\":[{\"message\":\"refused\"}]}"
        val server = serve { answer(it, 400, "application/json", refusal) }
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, server.url).send(query).toList() }
        assertEquals(400, failure.statusCode)
        assertEquals(refusal, failure.body)
    }

    @Test
    fun `a port nobody listens on fails with status 0 and says what went wrong`() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, "http://127.0.0.1:$port/graphql").send(query).toList() }
        assertEquals(0, failure.statusCode)
        assertTrue(failure.body.isNotEmpty(), "the failure says what went wrong")
    }

    @Test
    fun `a url no request can be sent to fails with status 0`() = runBlocking {
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, "not a url").send(query).toList() }
        assertEquals(0, failure.statusCode)
    }

    @Test
    fun `a collector that stops reading an event stream cancels the call, and the server sees the connection close`() = runBlocking {
        val closed = AtomicBoolean(false)
        val server = serve { exchange ->
            stream(exchange, 200, "text/event-stream") { output ->
                try {
                    output.writeInChunks("event: next\ndata: {\"data\":{}}\n\n")
                    // Keeps the stream open until a write finds the connection closed.
                    repeat(500) {
                        Thread.sleep(10)
                        output.writeInChunks(": keep-alive\n\n")
                    }
                } catch (_: IOException) {
                    closed.set(true)
                }
            }
        }
        val first = OkHttpTransport(client, server.url).send(subscription).first()
        assertEquals("{\"data\":{}}", first.decodeToString())
        assertTrue(calls.single().isCanceled(), "the call was cancelled")
        until("the server saw the connection close") { closed.get() }
    }

    @Test
    fun `cancelling the collector while the call waits for the response cancels the call`() = runBlocking {
        val released = CountDownLatch(1)
        // The server holds the response back until the test is done with it.
        val server = serve { released.await(10, TimeUnit.SECONDS) }
        val collecting = launch(Dispatchers.Default) { OkHttpTransport(client, server.url).send(query).toList() }
        until("the server received the request") { server.received.size == 1 }
        collecting.cancel()
        collecting.join()
        assertTrue(calls.single().isCanceled(), "the call was cancelled, not left to its read timeout")
        released.countDown()
    }
}
