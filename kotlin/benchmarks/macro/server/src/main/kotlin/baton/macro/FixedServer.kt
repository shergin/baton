package baton.macro

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

/**
 * An HTTP server on the loopback interface of the app's own process, which
 * answers a measured app's requests with bytes recorded once: the same
 * bytes for the same request every run, and no network between. It answers
 * the characters page by its `page` variable, a character's episodes by its
 * `id`, and every avatar with one recorded picture; anything else is a 404,
 * logged under the tag `FixedServer`, so a request the measurement did not
 * expect shows.
 *
 * Each client is answered with the text recorded for its own query, as the
 * store-level comparison reads them: [Client.BATON] the text of Baton's
 * query, [Client.APOLLO] the same data with the `__typename` Apollo's
 * normalizer asks of every object.
 */
class FixedServer private constructor(private val assets: AssetManager, private val client: Client) {
    /** Whose recorded answers the server gives. */
    enum class Client(val prefix: String) { BATON("baton"), APOLLO("apollo") }

    // IPv4's loopback by its address: Android's `getLoopbackAddress()` is
    // `::1`, which a client of `127.0.0.1` does not reach.
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))

    /** The server's origin, `http://127.0.0.1:<port>`. */
    val origin: String = "http://127.0.0.1:${socket.localPort}"

    /** The answers, read from the assets on the server's thread, so the app's start does not wait for them. */
    private val answers = HashMap<String, ByteArray>()
    private val loaded = CountDownLatch(1)

    /** The address on this server of a picture the API serves at [address]. */
    fun avatar(address: String): String = address.replace(API, origin)

    private fun run() {
        thread(name = "FixedServer", isDaemon = true) {
            for (name in ANSWERS) answers[name] = assets.open("${client.prefix}-$name").use { it.readBytes() }
            answers[AVATAR] = assets.open(AVATAR).use { it.readBytes() }
            loaded.countDown()
            while (true) {
                val connection = socket.accept()
                thread(name = "FixedServer connection", isDaemon = true) { serve(connection) }
            }
        }
    }

    /** Answers the requests of one connection, which a client may keep alive, until it closes. */
    private fun serve(connection: Socket) {
        connection.tcpNoDelay = true
        connection.use {
            val input = BufferedInputStream(it.getInputStream())
            val output = it.getOutputStream()
            while (true) {
                val request = Request.read(input) ?: return
                answer(request, output)
            }
        }
    }

    private fun answer(request: Request, output: OutputStream) {
        loaded.await()
        if (request.method == "GET" && request.path.startsWith("/api/character/avatar/")) {
            respond(output, 200, "image/jpeg", answers.getValue(AVATAR))
            return
        }
        val body = request.body.decodeToString()
        val operation = OPERATION.find(body)?.groupValues?.get(1)
        val name = when (operation) {
            "CharactersScreenQuery" -> PAGE.find(body)?.groupValues?.get(1)?.let { "characters-$it.json" }
            "CharacterEpisodesQuery" -> ID.find(body)?.groupValues?.get(1)?.let { "episodes-$it.json" }
            else -> null
        }
        val answer = name?.let(answers::get)
        if (answer == null) {
            Log.w(TAG, "no answer for ${request.method} ${request.path} $operation")
            respond(output, 404, "text/plain", "no recorded answer".encodeToByteArray())
            return
        }
        // A page's sections begin as its first byte is written and as its
        // last is; both end at the frame that draws the list.
        val list = operation == "CharactersScreenQuery"
        if (list) Sections.begin(Sections.LIST_RESPONSE_TO_FRAME)
        respond(output, 200, "application/json", answer)
        if (list) {
            Sections.begin(Sections.LIST_LAST_BYTE_TO_FRAME)
            Sections.begin(Sections.LIST_LAST_BYTE_TO_STORE)
        }
        Log.i(TAG, "answered $operation with $name, ${answer.size} bytes")
    }

    private fun respond(output: OutputStream, status: Int, type: String, body: ByteArray) {
        val reason = if (status == 200) "OK" else "Not Found"
        val head = "HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n\r\n"
        output.write(head.encodeToByteArray())
        output.write(body)
        output.flush()
    }

    /** One request: its method, its path and its body, chunked or of a stated length. */
    private class Request(val method: String, val path: String, val body: ByteArray) {
        companion object {
            fun read(input: InputStream): Request? {
                val line = readLine(input) ?: return null
                val parts = line.split(' ')
                if (parts.size < 2) return null
                var length = 0
                var chunked = false
                while (true) {
                    val header = readLine(input) ?: return null
                    if (header.isEmpty()) break
                    val colon = header.indexOf(':')
                    if (colon < 0) continue
                    val name = header.substring(0, colon).trim().lowercase()
                    val value = header.substring(colon + 1).trim()
                    if (name == "content-length") length = value.toInt()
                    if (name == "transfer-encoding" && value.equals("chunked", ignoreCase = true)) chunked = true
                }
                val body = if (chunked) readChunked(input) else readExactly(input, length)
                return Request(parts[0], parts[1], body)
            }

            private fun readChunked(input: InputStream): ByteArray {
                val body = ByteArrayOutputStream()
                while (true) {
                    val size = readLine(input)?.substringBefore(';')?.trim()?.toInt(16) ?: return body.toByteArray()
                    if (size == 0) {
                        readLine(input)
                        return body.toByteArray()
                    }
                    body.write(readExactly(input, size))
                    readLine(input)
                }
            }

            private fun readExactly(input: InputStream, count: Int): ByteArray {
                val bytes = ByteArray(count)
                var read = 0
                while (read < count) {
                    val received = input.read(bytes, read, count - read)
                    if (received < 0) break
                    read += received
                }
                return bytes
            }

            private fun readLine(input: InputStream): String? {
                val line = StringBuilder()
                while (true) {
                    val byte = input.read()
                    if (byte < 0) return if (line.isEmpty()) null else line.toString()
                    if (byte == '\n'.code) return line.toString().trimEnd('\r')
                    line.append(byte.toChar())
                }
            }
        }
    }

    companion object {
        /** The launch intent's boolean extra that asks the app to fetch from the fixed server. */
        const val EXTRA = "baton.macro.fixedServer"

        private const val TAG = "FixedServer"
        private const val API = "https://rickandmortyapi.com"
        private const val AVATAR = "avatar.jpeg"
        private val ANSWERS = listOf("characters-1.json", "characters-2.json", "episodes-9.json")
        private val OPERATION = Regex("\"operationName\"\\s*:\\s*\"(\\w+)\"")
        private val PAGE = Regex("\"page\"\\s*:\\s*(\\d+)")
        private val ID = Regex("\"id\"\\s*:\\s*\"(\\w+)\"")

        /** The server this process runs, once started. */
        @Volatile
        var current: FixedServer? = null
            private set

        /** Starts the process's server for [client], or returns the one it runs. */
        fun start(context: Context, client: Client): FixedServer = synchronized(this) {
            current ?: FixedServer(context.applicationContext.assets, client).also {
                it.run()
                current = it
            }
        }

        /** The server's `/graphql` address when the launch asked for the fixed server, else [live]. */
        fun graphql(live: String): String = current?.let { "${it.origin}/graphql" } ?: live
    }
}
