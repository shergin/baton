package baton

import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CompletionStage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

// The socket transport is the JVM's alone: `java.net.http.WebSocket` is the
// desktop JVM's, and Android's platform has no WebSocket client, so there an
// app brings its own transport.

/**
 * Operations over `graphql-transport-ws`: one WebSocket per transport, opened
 * on the first request with `connection_init` and its [connectionParams],
 * then `subscribe`, `next`, `error` and `complete` by id, every stream under
 * an id of its own, multiplexed on the one connection. A subscription's flow
 * is its events; a query's or a mutation's the one payload the server
 * completes after. The server's `ping` is answered with `pong`. The socket
 * closes when its last stream ends, and the next request opens another; a
 * socket that fails ends every stream on it with a `TransportError` of status
 * 0. An `error` frame ends its stream with the operation's `GraphQLErrors`.
 * Credentials are read when a connection is opened, after the fixed headers.
 * See `spec/runtime.md`, section 10.
 */
class GraphQLTransportWebSocket(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    /** Headers read when a connection is opened, after the fixed ones. */
    val credentials: suspend () -> Map<String, String> = { emptyMap() },
    val encoding: Encoding = Encoding.standard,
    /** The `payload` of `connection_init`, for authentication. */
    val connectionParams: Variable? = null,
) : Transport {
    private val client: HttpClient = HttpClient.newHttpClient()

    /**
     * Where the transport's state is read and written, one task at a time,
     * as the Swift transport's actor does; a task that suspends lets another
     * in, so each one checks again what it found before the suspension.
     */
    private val confined = Dispatchers.Default.limitedParallelism(1)

    /** Where the socket's frames are read and the server's pings answered. */
    private val scope = CoroutineScope(SupervisorJob() + confined)

    /** The connection streams join, from its opening to its close or failure. */
    private var connection: Connection? = null

    /** How many streams are joining the connection and are not yet listed in [subscribers], so it is not closed under them. */
    private var starting = 0

    /** The streams on the connection, by id. */
    private val subscribers = HashMap<String, Channel<ByteArray>>()

    /** One socket: its acknowledgement, the frames it delivered, and its sends, one at a time as `WebSocket` requires. */
    private class Connection {
        var socket: WebSocket? = null
        val acknowledged = CompletableDeferred<Unit>()
        val frames = Channel<Delivery>(Channel.UNLIMITED)
        val sending = Mutex()
    }

    /** What a socket delivered: a whole text frame, or its end. */
    private sealed interface Delivery {
        class Text(val text: String) : Delivery
        class Closed(val failure: Throwable) : Delivery
    }

    override fun send(request: Request): Flow<ByteArray> = flow {
        // Every stream is a subscription of its own, under its own id: equal requests must not stand in for one another
        // when one of them ends.
        val id = UUID.randomUUID().toString()
        val events = Channel<ByteArray>(Channel.UNLIMITED)
        try {
            withContext(confined) { start(id, request, events) }
            for (payload in events) emit(payload)
        } finally {
            withContext(NonCancellable + confined) { stop(id) }
        }
    }

    /** Joins or opens the connection, lists the stream and subscribes it. */
    private suspend fun start(id: String, request: Request, events: Channel<ByteArray>) {
        // Counted until it is listed or gives up, so the connection it opens or waits on is not closed under it.
        starting += 1
        val current = try {
            connect()
        } finally {
            starting -= 1
        }
        subscribers[id] = events
        val payload = encoding.body(request).decodeToString()
        send(current, "{\"id\":${Variable.quote(id)},\"type\":\"subscribe\",\"payload\":$payload}")
    }

    /**
     * Completes a stream the client stopped reading, or lets go of one that
     * never started. One the server ended is not listed and owes the server
     * nothing.
     */
    private suspend fun stop(id: String) {
        val listed = subscribers.remove(id) != null
        val current = connection
        if (listed && current != null) {
            try {
                send(current, "{\"id\":${Variable.quote(id)},\"type\":\"complete\"}")
            } catch (_: Exception) {
                // A socket that failed meanwhile has nothing to complete.
            }
        }
        closeIfUnused()
    }

    /**
     * The acknowledged connection: the one open or opening, joined, or a new
     * one. The transport opens it, not the stream that asked first, so a
     * stream that goes away while it opens leaves it to the others; a stream
     * cancelled while it waits gives up waiting.
     */
    private suspend fun connect(): Connection {
        val current = connection ?: Connection().also { opening ->
            connection = opening
            scope.launch {
                try {
                    open(opening)
                } catch (failure: Throwable) {
                    fail(opening, failure)
                }
            }
        }
        current.acknowledged.await()
        return current
    }

    /** Opens the socket of [current] and sends `connection_init`; its frames are read from here on. */
    private suspend fun open(current: Connection) {
        val read = credentials()
        val builder = client.newWebSocketBuilder().subprotocols("graphql-transport-ws")
        for ((name, value) in headers + read) builder.header(name, value)
        val socket = try {
            builder.buildAsync(URI(url), Listener(current.frames)).await()
        } catch (failure: Exception) {
            throw TransportError(0, "the socket could not be opened: ${failure.cause?.message ?: failure.message}")
        }
        // While it opened, every stream on it may have gone; then it is not this transport's to keep.
        if (connection !== current) {
            socket.abort()
            throw TransportError(0, "the socket is closed")
        }
        current.socket = socket
        scope.launch { for (delivery in current.frames) receive(current, delivery) }
        send(current, "{\"type\":\"connection_init\"${connectionParams?.let { ",\"payload\":${it.json}" } ?: ""}}")
    }

    private suspend fun send(current: Connection, text: String) {
        val socket = current.socket ?: throw TransportError(0, "the socket is closed")
        current.sending.withLock {
            try {
                socket.sendText(text, true).await()
            } catch (failure: Exception) {
                throw TransportError(0, "the socket could not send: ${failure.cause?.message ?: failure.message}")
            }
        }
    }

    /** Reads one delivery of a socket; one that is no longer the current one was closed on purpose, and nothing of it concerns the streams. */
    private fun receive(current: Connection, delivery: Delivery) {
        if (connection !== current) return
        when (delivery) {
            is Delivery.Closed -> fail(current, delivery.failure)
            is Delivery.Text -> try {
                handle(current, delivery.text.encodeToByteArray())
            } catch (failure: IngestError) {
                fail(current, TransportError(0, "the server sent a frame that is not JSON: ${failure.message}"))
            }
        }
    }

    private fun handle(current: Connection, frame: ByteArray) {
        var type: String? = null
        var id: String? = null
        var payload: ByteArray? = null
        val scanner = Scanner(frame)
        scanner.members { key ->
            when (key) {
                "type" -> type = scanner.stringValue()
                "id" -> id = scanner.stringValue()
                "payload" -> payload = scanner.rawValue()
                else -> scanner.skipValue()
            }
        }
        when (type) {
            "connection_ack" -> current.acknowledged.complete(Unit)
            "ping" -> scope.launch {
                try {
                    send(current, "{\"type\":\"pong\"}")
                } catch (_: TransportError) {
                    // A socket that failed is ended by its own delivery.
                }
            }
            "next" -> {
                val data = payload ?: return
                subscribers[id ?: return]?.trySend(data)
            }
            "error" -> {
                val stream = subscribers.remove(id ?: return) ?: return
                // The payload is the operation's GraphQL errors.
                val errors = payload?.let { bytes -> runCatching { Scanner(bytes).responseErrors() }.getOrNull() }.orEmpty()
                stream.close(if (errors.isEmpty()) GraphQLErrors(listOf("subscription error")) else requestErrors(errors))
                closeIfUnused()
            }
            "complete" -> {
                subscribers.remove(id ?: return)?.close()
                closeIfUnused()
            }
        }
    }

    /** Closes the connection when no stream is on it and none is joining it; the next request opens another. */
    private fun closeIfUnused() {
        val current = connection ?: return
        if (subscribers.isNotEmpty() || starting > 0) return
        connection = null
        current.frames.close()
        current.acknowledged.completeExceptionally(TransportError(0, "the socket is closed"))
        current.socket?.sendClose(WebSocket.NORMAL_CLOSURE, "")?.whenComplete { _, _ -> current.socket?.abort() }
    }

    /** Ends every stream on [current] and the connection; the next request opens another. */
    private fun fail(current: Connection, failure: Throwable) {
        if (connection !== current) return
        connection = null
        val error = failure as? TransportError ?: TransportError(0, failure.message ?: failure.toString())
        current.acknowledged.completeExceptionally(error)
        current.frames.close()
        for (stream in subscribers.values) stream.close(error)
        subscribers.clear()
        current.socket?.abort()
    }

    /** Hands a socket's whole text frames and its end to [frames], asking for one message at a time. */
    private class Listener(private val frames: Channel<Delivery>) : WebSocket.Listener {
        private val text = StringBuilder()

        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
            text.append(data)
            if (last) {
                frames.trySend(Delivery.Text(text.toString()))
                text.setLength(0)
            }
            webSocket.request(1)
            return null
        }

        override fun onBinary(webSocket: WebSocket, data: ByteBuffer, last: Boolean): CompletionStage<*>? {
            webSocket.request(1)
            return null
        }

        override fun onClose(webSocket: WebSocket, statusCode: Int, reason: String): CompletionStage<*>? {
            frames.trySend(Delivery.Closed(TransportError(0, "the socket closed with $statusCode${if (reason.isEmpty()) "" else ": $reason"}")))
            return null
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            frames.trySend(Delivery.Closed(TransportError(0, "the socket failed: ${error.message ?: error}")))
        }
    }
}
