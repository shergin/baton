package baton

import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.util.concurrent.CompletionStage
import kotlinx.coroutines.future.await

// The JVM's socket is `java.net.http.WebSocket`, the desktop JVM's and not
// Android's: there an app brings a client of its own, OkHttp's through
// `baton-okhttp`.

/** The JVM's WebSocket client, over `java.net.http`, with the [client] it opens sockets through. */
class JdkWebSocketClient(private val client: HttpClient = HttpClient.newHttpClient()) : WebSocketClient {
    override suspend fun open(url: String, protocol: String, headers: Map<String, String>, listener: WebSocketListener): WebSocketConnection {
        val builder = client.newWebSocketBuilder().subprotocols(protocol)
        for ((name, value) in headers) builder.header(name, value)
        val socket = try {
            builder.buildAsync(URI(url), Listener(listener)).await()
        } catch (failure: Exception) {
            throw TransportError(0, "the socket could not be opened: ${failure.cause?.message ?: failure.message}")
        }
        return Connection(socket)
    }

    /** One open socket, whose sends go one at a time as `WebSocket` requires of its caller. */
    private class Connection(private val socket: WebSocket) : WebSocketConnection {
        override suspend fun send(text: String) {
            try {
                socket.sendText(text, true).await()
            } catch (failure: Exception) {
                throw TransportError(0, "the socket could not send: ${failure.cause?.message ?: failure.message}")
            }
        }

        override fun close() {
            socket.sendClose(WebSocket.NORMAL_CLOSURE, "").whenComplete { _, _ -> socket.abort() }
        }

        override fun abort() {
            socket.abort()
        }
    }

    /** Assembles the socket's text frames whole, asking for one message at a time, and reports its end once. */
    private class Listener(private val delivery: WebSocketListener) : WebSocket.Listener {
        private val text = StringBuilder()

        override fun onOpen(webSocket: WebSocket) {
            webSocket.request(1)
        }

        override fun onText(webSocket: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
            text.append(data)
            if (last) {
                delivery.text(text.toString())
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
            delivery.closed(TransportError(0, "the socket closed with $statusCode${if (reason.isEmpty()) "" else ": $reason"}"))
            return null
        }

        override fun onError(webSocket: WebSocket, error: Throwable) {
            delivery.closed(TransportError(0, "the socket failed: ${error.message ?: error}"))
        }
    }
}

/**
 * The socket transport over the JVM's own client: [url] with [headers], the
 * [credentials] read when a connection opens, the [encoding] of the
 * subscribe payload and the [connectionParams] of `connection_init`.
 */
fun GraphQLTransportWebSocket(
    url: String,
    headers: Map<String, String> = emptyMap(),
    credentials: suspend () -> Map<String, String> = { emptyMap() },
    encoding: Encoding = Encoding.standard,
    connectionParams: Variable? = null,
): GraphQLTransportWebSocket = GraphQLTransportWebSocket(url, headers, credentials, encoding, connectionParams, JdkWebSocketClient())
