package baton

import baton.spec.TestHeaderQuery
import baton.spec.TestNoteAdded
import baton.spec.TestProfileQuery
import baton.testing.wait
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking

/** The HTTP transport against a server on the loopback interface, serving the specification's responses. */
class HttpTransportTests {
    /** What the server received of one request: its headers by lowercased name, and its body. */
    class Received(val headers: Map<String, String>, val body: String)

    /** A server on an ephemeral port that answers every request through [respond], keeping what it received. */
    class LocalServer(private val respond: (HttpExchange) -> Unit) {
        private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val received = CopyOnWriteArrayList<Received>()

        init {
            server.executor = Executors.newCachedThreadPool()
            server.createContext("/graphql") { exchange ->
                val headers = exchange.requestHeaders.entries.associate { it.key.lowercase() to it.value.joinToString(",") }
                received += Received(headers, exchange.requestBody.readBytes().decodeToString())
                try {
                    respond(exchange)
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

    @AfterTest
    fun stopServers() {
        servers.forEach { it.stop() }
    }

    /** Answers with [status], [contentType] and [body], written in chunks of [chunk] bytes, each flushed. */
    private fun answer(exchange: HttpExchange, status: Int, contentType: String, body: ByteArray, chunk: Int = body.size.coerceAtLeast(1)) {
        exchange.responseHeaders.add("Content-Type", contentType)
        exchange.sendResponseHeaders(status, 0)
        exchange.responseBody.use { output ->
            var offset = 0
            while (offset < body.size) {
                val end = minOf(offset + chunk, body.size)
                output.write(body, offset, end - offset)
                output.flush()
                offset = end
            }
        }
    }

    private val textRequest = Request("Stub", OperationKind.QUERY, Document.Text("query Stub { a }"), Variables.none)

    /**
     * An environment on the calling thread, which owns its store, reading
     * responses off it. A test ends it in a `finally`: once `runBlocking`
     * returns, its event loop hands what is dispatched to it to the default
     * executor, where the write observer of an environment left running
     * would send the apply notifications after every snapshot write the
     * later tests make.
     */
    private fun CoroutineScope.environment(transport: Transport, subscriptions: Transport? = null): Environment =
        Environment(transport, subscriptions, Store(), coroutineContext[ContinuationInterceptor] as CoroutineDispatcher, Dispatchers.Default)

    @Test
    fun `a plain response is one payload, and the request posts the encoded body as JSON, accepting a GraphQL response, with the fixed headers and the credentials`() = runBlocking {
        val server = serve { answer(it, 200, "application/json", Spec.bytes("tests/character-header-5.json")) }
        val transport = HttpTransport(server.url, headers = mapOf("X-Client" to "baton"), credentials = { mapOf("Authorization" to "Bearer token") })
        val payloads = transport.send(textRequest).toList()
        assertEquals(listOf(Spec.text("tests/character-header-5.json")), payloads.map { it.decodeToString() })
        val received = server.received.single()
        assertEquals(textRequest.body.decodeToString(), received.body)
        assertEquals("application/json", received.headers["content-type"])
        assertEquals("application/graphql-response+json, application/json", received.headers["accept"])
        assertEquals("baton", received.headers["x-client"])
        assertEquals("Bearer token", received.headers["authorization"])
    }

    @Test
    fun `the credentials are read for every attempt, so a rotated token reaches the next request, and over a fixed header of the same name`() = runBlocking {
        val server = serve { answer(it, 200, "application/json", "{\"data\":{}}".encodeToByteArray()) }
        val reads = AtomicInteger(0)
        val transport = HttpTransport(server.url, headers = mapOf("Authorization" to "fixed"), credentials = { mapOf("Authorization" to "Bearer ${reads.incrementAndGet()}") })
        val sent = transport.send(textRequest)
        sent.toList()
        sent.toList()
        assertEquals(listOf("Bearer 1", "Bearer 2"), server.received.map { it.headers["authorization"] })
    }

    @Test
    fun `an environment fetches a deferred query over multipart, each part committed as it arrives, leaving the case's store`() = runBlocking {
        val case = Spec.case("tests/character-deferred")
        val body = buildString {
            append("\r\n")
            for (response in case.responses) append("---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n").append(Spec.text(response).trimEnd()).append("\r\n")
            append("-----\r\n")
        }.encodeToByteArray()
        // Seven bytes at a time, so parts and delimiters straddle the reads.
        val server = serve { answer(it, 200, "multipart/mixed; boundary=\"-\"; deferSpec=20220824", body, chunk = 7) }
        val environment = environment(HttpTransport(server.url))
        try {
            environment.fetch(TestProfileQuery(id = "1"))
            assertEquals("multipart/mixed; deferSpec=20220824, application/graphql-response+json, application/json", server.received.single().headers["accept"])
            assertNull(case.difference(environment.store))
        } finally {
            environment.end()
        }
    }

    @Test
    fun `a subscription over HTTP asks for an event stream, commits each next event and ends at complete without opening it again`() = runBlocking {
        val events = buildString {
            append(": connected\n\n")
            append("event: next\ndata: ").append(Spec.text("tests/note-added-1.json").trim()).append("\n\n")
            append("event: complete\ndata:\n\n")
        }.encodeToByteArray()
        val server = serve { answer(it, 200, "text/event-stream", events, chunk = 5) }
        val environment = environment(HttpTransport("http://127.0.0.1:1/unused"), subscriptions = HttpTransport(server.url))
        try {
            val handle = environment.subscriptionHandle(TestNoteAdded(characterId = "1", connections = emptyList()))
            val hold = handle.retain()
            assertTrue(wait({ handle.stream is Stream.Ended }), "the stream ended: ${handle.stream}")
            assertEquals(Stream.Ended(null), handle.stream)
            assertEquals(1, handle.events)
            assertEquals("text/event-stream, application/graphql-response+json, application/json", server.received.single().headers["accept"])
            assertEquals(1, server.received.size, "a completed stream is not opened again")
            hold.release()
        } finally {
            environment.end()
        }
    }

    @Test
    fun `a response outside 2xx fails with its status and its body`() = runBlocking {
        val server = serve { answer(it, 500, "text/plain", "down for maintenance".encodeToByteArray()) }
        val failure = assertFailsWith<TransportError> { HttpTransport(server.url).send(textRequest).toList() }
        assertEquals(500, failure.statusCode)
        assertEquals("down for maintenance", failure.body)
        assertEquals("HTTP 500: down for maintenance", failure.message)
    }

    @Test
    fun `a 4xx answered as a GraphQL response of errors and no data fails a handle with those errors, the request kind of failure`() = runBlocking {
        val refusal = "{\"errors\":[{\"message\":\"Cannot query field \\\"nope\\\" on type \\\"Query\\\".\",\"extensions\":{\"code\":\"GRAPHQL_VALIDATION_FAILED\"}}]}"
        val server = serve { answer(it, 400, "application/graphql-response+json; charset=utf-8", refusal.encodeToByteArray()) }
        val environment = environment(HttpTransport(server.url))
        try {
            val handle = environment.handle(TestHeaderQuery(id = "5"))
            val hold = handle.retain()
            handle.settle()
            val errors = assertIs<GraphQLErrors>(assertIs<Phase.Failed>(handle.phase).error)
            assertEquals(listOf("Cannot query field \"nope\" on type \"Query\"."), errors.messages)
            assertEquals(Variable.Object(mapOf("code" to Variable.String("GRAPHQL_VALIDATION_FAILED"))), errors.errors.single().extensions)
            assertIs<Failure.Request>(handle.fetch.failure)
            hold.release()
        } finally {
            environment.end()
        }
    }

    @Test
    fun `a 4xx answered as plain JSON stays a transport error with its status and body`() = runBlocking {
        val refusal = "{\"errors\":[{\"message\":\"refused\"}]}"
        val server = serve { answer(it, 400, "application/json", refusal.encodeToByteArray()) }
        val failure = assertFailsWith<TransportError> { HttpTransport(server.url).send(textRequest).toList() }
        assertEquals(400, failure.statusCode)
        assertEquals(refusal, failure.body)
    }

    @Test
    fun `a refused connection fails with status 0 and says what went wrong`() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }
        val failure = assertFailsWith<TransportError> { HttpTransport("http://127.0.0.1:$port/graphql").send(textRequest).toList() }
        assertEquals(0, failure.statusCode)
        assertTrue(failure.body.isNotEmpty(), "the failure says what went wrong")
        assertEquals(failure.body, failure.message)
    }

    @Test
    fun `a url no request can be sent to fails with status 0`() = runBlocking {
        val failure = assertFailsWith<TransportError> { HttpTransport("not a url").send(textRequest).toList() }
        assertEquals(0, failure.statusCode)
    }

    @Test
    fun `a collector that stops reading an event stream closes the connection, which the server sees`() = runBlocking {
        val closed = AtomicBoolean(false)
        val server = serve { exchange ->
            exchange.responseHeaders.add("Content-Type", "text/event-stream")
            exchange.sendResponseHeaders(200, 0)
            val output = exchange.responseBody
            try {
                output.write("event: next\ndata: {\"data\":{}}\n\n".encodeToByteArray())
                output.flush()
                // Keeps the stream open until a write finds the connection closed.
                repeat(500) {
                    Thread.sleep(10)
                    output.write(": keep-alive\n\n".encodeToByteArray())
                    output.flush()
                }
            } catch (_: IOException) {
                closed.set(true)
            }
        }
        val request = Request("Stub", OperationKind.SUBSCRIPTION, Document.Text("subscription Stub { a }"), Variables.none)
        val first = HttpTransport(server.url).send(request).first()
        assertEquals("{\"data\":{}}", first.decodeToString())
        assertTrue(wait({ closed.get() }), "the server saw the connection close")
    }
}
