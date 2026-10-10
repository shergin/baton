package baton.okhttp

import baton.TransportError
import baton.WebSocketClient
import baton.WebSocketConnection
import baton.WebSocketListener
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket

/**
 * A WebSocket client over an [OkHttpClient], for the runtime's socket
 * transport: `GraphQLTransportWebSocket(url, client = OkHttpWebSocketClient(okHttp))`
 * speaks `graphql-transport-ws` over the sockets this opens. On Android,
 * whose platform has no WebSocket client, this is the socket transport's
 * client.
 */
class OkHttpWebSocketClient(private val client: OkHttpClient) : WebSocketClient {
    override suspend fun open(url: String, protocol: String, headers: Map<String, String>, listener: WebSocketListener): WebSocketConnection {
        val builder = try {
            okhttp3.Request.Builder().url(url)
        } catch (failure: IllegalArgumentException) {
            throw TransportError(0, "the socket could not be opened: ${failure.message}")
        }
        builder.header("Sec-WebSocket-Protocol", protocol)
        for ((name, value) in headers) builder.header(name, value)
        val opened = CompletableDeferred<WebSocketConnection>()
        val ended = AtomicBoolean(false)
        val socket = client.newWebSocket(
            builder.build(),
            object : okhttp3.WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened.complete(Connection(webSocket))
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    listener.text(text)
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    // The server began the closing handshake; the socket finishes it with a normal closure of its own,
                    // since a code the server left out reads as one OkHttp refuses to send back.
                    webSocket.close(NORMAL_CLOSURE, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    if (ended.compareAndSet(false, true)) {
                        listener.closed(TransportError(0, "the socket closed with $code${if (reason.isEmpty()) "" else ": $reason"}"))
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    val failure = TransportError(0, "the socket failed: ${t.message ?: t}", t)
                    if (!opened.isCompleted) {
                        opened.completeExceptionally(TransportError(0, "the socket could not be opened: ${t.message ?: t}", t))
                        return
                    }
                    if (ended.compareAndSet(false, true)) listener.closed(failure)
                }
            },
        )
        try {
            return opened.await()
        } catch (failure: Throwable) {
            // A failure to open, or the caller cancelled while it opened: the socket is not kept.
            socket.cancel()
            throw failure
        }
    }

    /** One open socket: OkHttp queues its sends and writes them in order. */
    private class Connection(private val socket: WebSocket) : WebSocketConnection {
        override suspend fun send(text: String) {
            if (!socket.send(text)) throw TransportError(0, "the socket could not send: it is closed or its queue is full")
        }

        override fun close() {
            socket.close(NORMAL_CLOSURE, null)
        }

        override fun abort() {
            socket.cancel()
        }
    }

    private companion object {
        const val NORMAL_CLOSURE = 1000
    }
}
