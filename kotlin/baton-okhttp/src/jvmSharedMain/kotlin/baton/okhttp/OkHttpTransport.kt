package baton.okhttp

import baton.Encoding
import baton.EventStreamParser
import baton.MultipartParser
import baton.Request
import baton.Transport
import baton.TransportError
import baton.accept
import baton.answersInGraphQLResponse
import baton.requestErrors
import java.io.IOException
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
import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer

/**
 * POSTs operations as JSON to one endpoint over an [OkHttpClient], the app's
 * own with its interceptors, timeouts and pool, and reads the response as
 * the runtime's `HttpTransport` reads it: one payload, the parts of a
 * deferred response as they arrive over `multipart/mixed`, or the events of
 * a subscription over `text/event-stream`. Credentials are read per attempt,
 * after the fixed headers, so a rotated token reaches the next request. A
 * response outside 2xx fails with a `TransportError` of its status and body,
 * unless it is a request error answered as `application/graphql-response+json`,
 * which fails with its `GraphQLErrors`; no response at all fails with
 * status 0 and what went wrong. The flow is cold: each collection is one
 * call, and its cancellation cancels the call.
 */
class OkHttpTransport(
    val client: OkHttpClient,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    /** Headers read for every attempt, after the fixed ones. */
    val credentials: suspend () -> Map<String, String> = { emptyMap() },
    val encoding: Encoding = Encoding.standard,
) : Transport {
    override fun send(request: Request): Flow<ByteArray> = flow {
        val credentials = credentials()
        val builder = try {
            okhttp3.Request.Builder().url(url)
        } catch (failure: IllegalArgumentException) {
            throw TransportError(0, "the url $url is not one a request can be sent to: ${failure.message}")
        }
        builder.post(encoding.body(request).toRequestBody(JSON))
        builder.header("Accept", request.accept)
        for ((name, value) in headers) builder.header(name, value)
        for ((name, value) in credentials) builder.header(name, value)
        val call = client.newCall(builder.build())
        coroutineScope {
            // The call's reads block their thread; a cancellation reaches them by cancelling the call under them.
            val ended = AtomicBoolean(false)
            val cancelling = launch {
                try {
                    awaitCancellation()
                } finally {
                    if (!ended.get()) call.cancel()
                }
            }
            try {
                exchange(call)
                ended.set(true)
            } catch (failure: IOException) {
                // A read that failed because the collector went away is the cancellation, not a failure.
                currentCoroutineContext().ensureActive()
                throw TransportError(0, failure.message ?: failure.toString(), failure)
            } finally {
                cancelling.cancel()
            }
        }
    }.flowOn(Dispatchers.IO)

    /** Executes the call and emits the response's payloads, by its status and its content type. */
    private suspend fun FlowCollector<ByteArray>.exchange(call: Call) {
        call.execute().use { response -> deliver(response) }
    }

    private suspend fun FlowCollector<ByteArray>.deliver(response: Response) {
        val status = response.code
        val contentType = response.header("Content-Type") ?: ""
        val body = response.body
        if (status !in 200..299) {
            val refused = body.bytes()
            // A server of the GraphQL-over-HTTP media type answers a request error, a response without data, with a 4xx
            // or 5xx status: its errors are the request kind of failure, not the transport's.
            if (answersInGraphQLResponse(contentType)) requestErrors(refused)?.let { throw it }
            throw TransportError(status, refused.decodeToString())
        }
        val boundary = MultipartParser.boundary(contentType)
        when {
            boundary != null -> {
                val parser = MultipartParser(boundary)
                read(response) { chunk, count -> for (part in parser.push(chunk, 0, count)) emit(part) }
                for (part in parser.finish()) emit(part)
            }
            EventStreamParser.frames(contentType) -> {
                val parser = EventStreamParser()
                read(response) { chunk, count -> for (payload in parser.push(chunk, 0, count)) emit(payload) }
                for (payload in parser.finish()) emit(payload)
            }
            else -> emit(body.bytes())
        }
    }

    /** Reads the body in the chunks the source hands over until it ends, each to [chunk] with its count of bytes. */
    private inline fun read(response: Response, chunk: (ByteArray, Int) -> Unit) {
        val source = response.body.source()
        val buffer = Buffer()
        while (true) {
            val count = source.read(buffer, CHUNK)
            if (count < 0) return
            if (count > 0) {
                val bytes = buffer.readByteArray()
                chunk(bytes, bytes.size)
            }
        }
    }

    private companion object {
        val JSON = "application/json".toMediaType()
        const val CHUNK = 16L * 1024
    }
}
