package baton

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * A `graphql-transport-ws` server on the loopback interface, as small as the
 * tests need: it accepts the handshake, acknowledges `connection_init` unless
 * told not to, keeps every message a client sent, and sends what a test tells
 * it to, on the socket that subscribed last. Written over plain sockets, since
 * the JDK has a WebSocket client and no server.
 */
class SocketServer(private val acknowledges: Boolean = true) {
    /** A message a client sent: its type, its id, and its payload as JSON text. */
    class Message(val type: String?, val id: String?, val payload: String?)

    private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val connections = CopyOnWriteArrayList<Connection>()
    private val closings = AtomicInteger(0)

    val messages = CopyOnWriteArrayList<Message>()

    /** The `Sec-WebSocket-Protocol` and `Authorization` headers of each handshake, in order. */
    val offeredProtocols = CopyOnWriteArrayList<String>()
    val authorizations = CopyOnWriteArrayList<String>()

    /** How many sockets have closed. */
    val closed: Int get() = closings.get()

    /** How many sockets were opened. */
    val opened: Int get() = connections.size

    val url: String get() = "ws://127.0.0.1:${server.localPort}/graphql"

    init {
        thread(isDaemon = true, name = "socket-server") {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (_: IOException) {
                    return@thread
                }
                val connection = Connection(socket)
                connections += connection
                thread(isDaemon = true, name = "socket-server-connection") { connection.serve() }
            }
        }
    }

    fun count(type: String): Int = messages.count { it.type == type }

    fun ids(type: String): List<String> = messages.filter { it.type == type }.mapNotNull { it.id }

    fun payloads(type: String): List<String> = messages.filter { it.type == type }.mapNotNull { it.payload }

    /** Sends a text frame on the newest socket. */
    fun send(text: String) {
        connections.last().send(text)
    }

    /** Acknowledges the newest socket's `connection_init`. */
    fun acknowledge() {
        send("{\"type\":\"connection_ack\"}")
    }

    /** Closes the newest socket from the server's side. */
    fun hangUp() {
        connections.last().closeFrame(1011)
    }

    fun stop() {
        server.close()
        for (connection in connections) runCatching { connection.socket.close() }
    }

    private inner class Connection(val socket: Socket) {
        private val output: OutputStream = socket.getOutputStream()
        private var closedOnce = false

        fun serve() {
            try {
                val input = socket.getInputStream()
                handshake(input)
                val text = ByteArrayOutputStream()
                while (true) {
                    val first = input.read()
                    if (first < 0) break
                    val opcode = first and 0x0F
                    val final = first and 0x80 != 0
                    val payload = payload(input)
                    when (opcode) {
                        0x0, 0x1 -> {
                            text.write(payload)
                            if (final) {
                                receive(text.toString(Charsets.UTF_8))
                                text.reset()
                            }
                        }
                        0x8 -> {
                            closeFrame(1000)
                            break
                        }
                        0x9 -> frame(0xA, payload)
                    }
                }
            } catch (_: IOException) {
                // The client went away.
            } finally {
                runCatching { socket.close() }
                closings.incrementAndGet()
            }
        }

        private fun handshake(input: InputStream) {
            val lines = ArrayList<String>()
            val line = StringBuilder()
            while (true) {
                val byte = input.read()
                if (byte < 0) throw EOFException()
                if (byte == '\n'.code) {
                    val read = line.toString().trimEnd('\r')
                    line.setLength(0)
                    if (read.isEmpty()) break
                    lines += read
                } else {
                    line.append(byte.toChar())
                }
            }
            val headers = lines.drop(1).associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim() }
            offeredProtocols += headers["sec-websocket-protocol"].orEmpty()
            headers["authorization"]?.let { authorizations += it }
            val key = headers["sec-websocket-key"].orEmpty()
            val accept = Base64.getEncoder().encodeToString(
                MessageDigest.getInstance("SHA-1").digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()),
            )
            val response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: $accept\r\nSec-WebSocket-Protocol: graphql-transport-ws\r\n\r\n"
            synchronized(output) {
                output.write(response.toByteArray())
                output.flush()
            }
        }

        /** A client frame's payload, unmasked. */
        private fun payload(input: InputStream): ByteArray {
            val second = input.read()
            if (second < 0) throw EOFException()
            var length = (second and 0x7F).toLong()
            if (length == 126L) length = (read(input, 2)).fold(0L) { total, byte -> (total shl 8) or (byte.toLong() and 0xFF) }
            if (length == 127L) length = (read(input, 8)).fold(0L) { total, byte -> (total shl 8) or (byte.toLong() and 0xFF) }
            val mask = if (second and 0x80 != 0) read(input, 4) else null
            val payload = read(input, length.toInt())
            if (mask != null) for (index in payload.indices) payload[index] = (payload[index].toInt() xor mask[index % 4].toInt()).toByte()
            return payload
        }

        private fun read(input: InputStream, count: Int): ByteArray {
            val bytes = input.readNBytes(count)
            if (bytes.size < count) throw EOFException()
            return bytes
        }

        private fun receive(text: String) {
            @Suppress("UNCHECKED_CAST")
            val message = Json.parse(text) as Map<String, Any?>
            val payload = if ("payload" in message) Json.write(message["payload"]) else null
            messages += Message(message["type"] as String?, message["id"] as String?, payload)
            if (message["type"] == "connection_init" && acknowledges) send("{\"type\":\"connection_ack\"}")
        }

        fun send(text: String) {
            frame(0x1, text.toByteArray())
        }

        fun closeFrame(code: Int) {
            synchronized(output) {
                if (closedOnce) return
                closedOnce = true
            }
            runCatching { frame(0x8, byteArrayOf((code shr 8).toByte(), code.toByte())) }
            if (code != 1000) runCatching { socket.shutdownOutput() }
        }

        private fun frame(opcode: Int, payload: ByteArray) {
            synchronized(output) {
                output.write(0x80 or opcode)
                when {
                    payload.size < 126 -> output.write(payload.size)
                    payload.size < 65536 -> {
                        output.write(126)
                        output.write(payload.size shr 8)
                        output.write(payload.size and 0xFF)
                    }
                    else -> {
                        output.write(127)
                        for (shift in 56 downTo 0 step 8) output.write(((payload.size.toLong() shr shift) and 0xFF).toInt())
                    }
                }
                output.write(payload)
                output.flush()
            }
        }
    }
}
