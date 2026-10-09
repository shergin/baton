package baton.okhttp

import androidx.test.ext.junit.runners.AndroidJUnit4
import baton.Document
import baton.Encoding
import baton.GraphQLErrors
import baton.OperationKind
import baton.Request
import baton.TransportError
import baton.Variable
import baton.Variables
import baton.testing.wait
import java.io.IOException
import java.io.OutputStream
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
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
import org.junit.runner.RunWith

/**
 * The HTTP transport over OkHttp on a device, against [LocalServer] on the
 * loopback interface: the JVM's `OkHttpTransportTests`, test for test, on
 * Android's runtime. The names are spelled with underscores, which a DEX
 * file of this module's lowest API level allows where spaces and commas are
 * refused.
 */
@RunWith(AndroidJUnit4::class)
class OkHttpTransportTests {
    private val servers = ArrayList<LocalServer>()

    private fun serve(respond: (LocalServer.Exchange) -> Unit): LocalServer = LocalServer(respond).also(servers::add)

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
    private fun stream(exchange: LocalServer.Exchange, status: Int, contentType: String, writing: (OutputStream) -> Unit) {
        exchange.respond(status, contentType).use(writing)
    }

    /** Answers with [status], [contentType] and [body]. */
    private fun answer(exchange: LocalServer.Exchange, status: Int, contentType: String, body: String) {
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
    fun a_query_posts_the_encoding_s_json_with_the_json_content_type_the_fixed_headers_and_the_credentials_accepting_a_graphql_response_and_receives_the_one_payload() = runBlocking {
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
    fun another_encoding_writes_the_body() = runBlocking {
        val server = serve { answer(it, 200, "application/json", "{\"data\":{}}") }
        val byId = Encoding { sent -> "{\"id\":${Variable.quote((sent.document as? Document.Id)?.id ?: "")}}".encodeToByteArray() }
        val persisted = Request("Stub", OperationKind.QUERY, Document.Id("0a1b2c"), Variables.none)
        OkHttpTransport(client, server.url, encoding = byId).send(persisted).toList()
        assertEquals("{\"id\":\"0a1b2c\"}", server.received.single().body)
    }

    @Test
    fun the_credentials_are_read_for_every_attempt_so_a_rotated_token_reaches_the_next_request_and_replace_a_fixed_header_of_the_same_name() = runBlocking {
        val server = serve { answer(it, 200, "application/json", "{\"data\":{}}") }
        val reads = AtomicInteger(0)
        val transport = OkHttpTransport(client, server.url, headers = mapOf("Authorization" to "fixed"), credentials = { mapOf("Authorization" to "Bearer ${reads.incrementAndGet()}") })
        val sent = transport.send(query)
        sent.toList()
        sent.toList()
        assertEquals(listOf("Bearer 1", "Bearer 2"), server.received.map { it.headers["authorization"] })
    }

    @Test
    fun a_deferred_operation_asks_for_multipart_and_receives_each_part_as_it_arrives() = runBlocking {
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
    fun a_subscription_asks_for_an_event_stream_and_receives_each_event_as_it_arrives() = runBlocking {
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
    fun a_response_outside_2xx_fails_with_a_transport_error_of_its_status_and_its_body() = runBlocking {
        val server = serve { answer(it, 500, "text/plain", "down for maintenance") }
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, server.url).send(query).toList() }
        assertEquals(500, failure.statusCode)
        assertEquals("down for maintenance", failure.body)
    }

    @Test
    fun a_request_error_answered_as_a_graphql_response_fails_with_its_graphql_errors() = runBlocking {
        val refusal = "{\"errors\":[{\"message\":\"Cannot query field \\\"nope\\\" on type \\\"Query\\\".\",\"extensions\":{\"code\":\"GRAPHQL_VALIDATION_FAILED\"}}]}"
        val server = serve { answer(it, 400, "application/graphql-response+json; charset=utf-8", refusal) }
        val errors = assertFailsWith<GraphQLErrors> { OkHttpTransport(client, server.url).send(query).toList() }
        assertEquals(listOf("Cannot query field \"nope\" on type \"Query\"."), errors.messages)
        assertEquals(Variable.Object(mapOf("code" to Variable.String("GRAPHQL_VALIDATION_FAILED"))), errors.errors.single().extensions)
    }

    @Test
    fun a_request_error_answered_as_plain_json_stays_a_transport_error_of_its_status_and_its_body() = runBlocking {
        val refusal = "{\"errors\":[{\"message\":\"refused\"}]}"
        val server = serve { answer(it, 400, "application/json", refusal) }
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, server.url).send(query).toList() }
        assertEquals(400, failure.statusCode)
        assertEquals(refusal, failure.body)
    }

    @Test
    fun a_port_nobody_listens_on_fails_with_status_0_and_says_what_went_wrong() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, "http://127.0.0.1:$port/graphql").send(query).toList() }
        assertEquals(0, failure.statusCode)
        assertTrue(failure.body.isNotEmpty(), "the failure says what went wrong")
    }

    @Test
    fun a_url_no_request_can_be_sent_to_fails_with_status_0() = runBlocking {
        val failure = assertFailsWith<TransportError> { OkHttpTransport(client, "not a url").send(query).toList() }
        assertEquals(0, failure.statusCode)
    }

    @Test
    fun a_collector_that_stops_reading_an_event_stream_cancels_the_call_and_the_server_sees_the_connection_close() = runBlocking {
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
    fun cancelling_the_collector_while_the_call_waits_for_the_response_cancels_the_call() = runBlocking {
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
