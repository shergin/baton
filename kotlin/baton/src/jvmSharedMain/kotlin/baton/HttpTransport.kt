package baton

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.MalformedURLException
import java.net.URI
import java.net.URISyntaxException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch

// The HTTP transport uses `java.net` alone, which the JVM and Android share.

/**
 * POSTs operations as JSON to one endpoint over `HttpURLConnection`. An
 * operation with `@defer` asks for `multipart/mixed` and reads the parts as
 * they arrive; a subscription asks for `text/event-stream` and reads its
 * events, `graphql-sse` in its distinct-connections mode. Credentials are
 * read per attempt, after the fixed headers, so a rotated token reaches the
 * next request. A response outside 2xx fails with a `TransportError` of its
 * status and body, unless it is a request error answered as
 * `application/graphql-response+json`, which fails with its `GraphQLErrors`;
 * no response at all fails with status 0 and what went wrong. The flow is
 * cold: each collection is one attempt, and its cancellation closes the
 * connection. See `spec/runtime.md`, section 10.
 */
class HttpTransport(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    /** Headers read for every attempt, after the fixed ones: a credential a session rotates reaches each request as it is made. */
    val credentials: suspend () -> Map<String, String> = { emptyMap() },
    val encoding: Encoding = Encoding.standard,
) : Transport {
    override fun send(request: Request): Flow<ByteArray> = flow {
        val credentials = credentials()
        val body = encoding.body(request)
        val connection = try {
            URI(url).toURL().openConnection() as? HttpURLConnection
        } catch (failure: URISyntaxException) {
            throw TransportError(0, "the url $url is not one a request can be sent to: ${failure.message}")
        } catch (failure: IllegalArgumentException) {
            throw TransportError(0, "the url $url is not one a request can be sent to: ${failure.message}")
        } catch (failure: MalformedURLException) {
            throw TransportError(0, "the url $url is not one a request can be sent to: ${failure.message}")
        } ?: throw TransportError(0, "the url $url is not an HTTP one")
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.useCaches = false
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("Accept", accept(request))
        for ((name, value) in headers) connection.setRequestProperty(name, value)
        for ((name, value) in credentials) connection.setRequestProperty(name, value)
        coroutineScope {
            // The connection's reads block their thread; a cancellation reaches them by closing the connection under
            // them. An exchange that ended on its own leaves the connection to the pool.
            val ended = AtomicBoolean(false)
            val closing = launch {
                try {
                    awaitCancellation()
                } finally {
                    if (!ended.get()) connection.disconnect()
                }
            }
            try {
                exchange(connection, body)
                ended.set(true)
            } catch (failure: IOException) {
                // A read that failed because the collector went away is the cancellation, not a failure.
                currentCoroutineContext().ensureActive()
                throw TransportError(0, failure.message ?: failure.toString())
            } finally {
                closing.cancel()
            }
        }
    }.flowOn(Dispatchers.IO)

    /** Sends the body and emits the response's payloads, by its status and its content type. */
    private suspend fun FlowCollector<ByteArray>.exchange(connection: HttpURLConnection, body: ByteArray) {
        connection.outputStream.use { it.write(body) }
        val status = connection.responseCode
        val contentType = connection.contentType ?: ""
        if (status !in 200..299) {
            val refused = connection.errorStream?.use { it.readBytes() } ?: ByteArray(0)
            // A server of the GraphQL-over-HTTP media type answers a request error, a response without data, with a 4xx or 5xx
            // status: its errors are the request kind of failure, not the transport's.
            if (answersInGraphQLResponse(contentType)) requestErrors(refused)?.let { throw it }
            throw TransportError(status, refused.decodeToString())
        }
        connection.inputStream.use { input ->
            val boundary = MultipartParser.boundary(contentType)
            when {
                boundary != null -> {
                    val parser = MultipartParser(boundary)
                    read(input) { chunk, count -> for (part in parser.push(chunk, 0, count)) emit(part) }
                    for (part in parser.finish()) emit(part)
                }
                EventStreamParser.frames(contentType) -> {
                    val parser = EventStreamParser()
                    read(input) { chunk, count -> for (payload in parser.push(chunk, 0, count)) emit(payload) }
                    for (payload in parser.finish()) emit(payload)
                }
                else -> emit(input.readBytes())
            }
        }
    }

    /** Reads [input] in the chunks it hands over until it ends, each to [chunk] with the count of bytes read. */
    private inline fun read(input: InputStream, chunk: (ByteArray, Int) -> Unit) {
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return
            if (count > 0) chunk(buffer, count)
        }
    }

    private companion object {
        /** What a request accepts: an event stream for a subscription, multipart for a deferred operation, one response otherwise. */
        fun accept(request: Request): String = when {
            request.kind == OperationKind.SUBSCRIPTION -> "text/event-stream, application/graphql-response+json, application/json"
            request.incremental -> "multipart/mixed; deferSpec=20220824, application/graphql-response+json, application/json"
            else -> "application/graphql-response+json, application/json"
        }
    }
}

/**
 * An environment over HTTP: an `HttpTransport` to [url] with [headers], the
 * transport [subscriptions] go through when given, and [store], made on the
 * thread it will belong to. It commits on the main dispatcher, so it is made
 * there too.
 */
fun Environment(
    url: String,
    headers: Map<String, String> = emptyMap(),
    subscriptions: Transport? = null,
    store: Store = Store(),
): Environment = Environment(HttpTransport(url, headers), subscriptions, store)
