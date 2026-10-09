package baton.okhttp

import java.io.BufferedInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/** What the server received of one request: its method, its headers by lowercased name, and its body. */
class Received(val method: String, val headers: Map<String, String>, val body: String)

/**
 * An HTTP/1.1 server on the loopback interface for the transport's tests on
 * a device, where the JDK's `com.sun.net.httpserver` does not exist: it reads
 * each request's line, headers and body, keeps them, and hands an [Exchange]
 * to [respond]. A body is chunked, each write one chunk, as the JDK's server
 * writes a body of unknown length; the connection closes after it.
 */
class LocalServer(private val respond: (Exchange) -> Unit) {
    // The IPv4 loopback address, which the url names, by its bytes: Android's `getLoopbackAddress` is the IPv6 one.
    private val server = ServerSocket(0, 50, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
    private val sockets = CopyOnWriteArrayList<Socket>()
    val received = CopyOnWriteArrayList<Received>()

    val url: String get() = "http://127.0.0.1:${server.localPort}/graphql"

    init {
        thread(isDaemon = true, name = "local-server") {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (_: IOException) {
                    return@thread
                }
                sockets += socket
                thread(isDaemon = true, name = "local-server-exchange") { serve(socket) }
            }
        }
    }

    fun stop() {
        server.close()
        for (socket in sockets) runCatching { socket.close() }
    }

    private fun serve(socket: Socket) {
        try {
            val input = BufferedInputStream(socket.getInputStream())
            val head = head(input)
            val headers = head.drop(1)
                .groupBy({ it.substringBefore(':').trim().lowercase() }, { it.substringAfter(':').trim() })
                .mapValues { (_, values) -> values.joinToString(",") }
            val body = read(input, headers["content-length"]?.toInt() ?: 0)
            received += Received(head.first().substringBefore(' '), headers, body.decodeToString())
            respond(Exchange(socket.getOutputStream()))
        } catch (_: IOException) {
            // The client went away.
        } finally {
            runCatching { socket.close() }
        }
    }

    /** The request line and the header lines, up to the blank line that ends them. */
    private fun head(input: InputStream): List<String> {
        val lines = ArrayList<String>()
        val line = StringBuilder()
        while (true) {
            val byte = input.read()
            if (byte < 0) throw EOFException()
            if (byte != '\n'.code) {
                line.append(byte.toChar())
                continue
            }
            val read = line.toString().trimEnd('\r')
            line.setLength(0)
            if (read.isEmpty()) return lines
            lines += read
        }
    }

    /** Exactly [count] bytes of [input]. */
    private fun read(input: InputStream, count: Int): ByteArray {
        val bytes = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(bytes, offset, count - offset)
            if (read < 0) throw EOFException()
            offset += read
        }
        return bytes
    }

    /** One request's answer: [respond] sends the status line and the headers, and the body written to the stream it returns follows. */
    class Exchange(private val output: OutputStream) {
        fun respond(status: Int, contentType: String): OutputStream {
            val reason = if (status in 200..299) "OK" else "Error"
            output.write("HTTP/1.1 $status $reason\r\nContent-Type: $contentType\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".encodeToByteArray())
            output.flush()
            return ChunkedBody(output)
        }
    }

    /** A body in the chunked coding: every write a chunk, and the last, empty chunk on close. */
    private class ChunkedBody(private val output: OutputStream) : OutputStream() {
        override fun write(byte: Int) {
            write(byteArrayOf(byte.toByte()), 0, 1)
        }

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            if (length == 0) return
            output.write("${length.toString(16)}\r\n".encodeToByteArray())
            output.write(bytes, offset, length)
            output.write("\r\n".encodeToByteArray())
        }

        override fun flush() {
            output.flush()
        }

        override fun close() {
            output.write("0\r\n\r\n".encodeToByteArray())
            output.flush()
        }
    }
}
