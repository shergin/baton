package baton

// How a response's bytes are framed into payloads, for every target's
// transports: the parts of a `multipart/mixed` body and the events of a
// `text/event-stream` one, and the request error a refused response carries.
// The transports themselves are each target's actuals.

private const val LINE_FEED: Byte = 0x0A
private const val CARRIAGE_RETURN: Byte = 0x0D
private const val HYPHEN: Byte = 0x2D
private const val COLON: Byte = 0x3A
private const val SPACE: Byte = 0x20

/** A byte buffer that grows at its end and lets go of its start. */
private class Bytes {
    var array = ByteArray(256)
        private set
    var count = 0
        private set

    operator fun get(index: Int): Byte = array[index]

    fun append(chunk: ByteArray, start: Int, end: Int) {
        val needed = count + (end - start)
        if (needed > array.size) array = array.copyOf(maxOf(needed, array.size * 2))
        chunk.copyInto(array, count, start, end)
        count = needed
    }

    /** Drops the first [length] bytes. */
    fun drop(length: Int) {
        if (length == 0) return
        array.copyInto(array, 0, length, count)
        count -= length
    }

    fun clear() {
        count = 0
    }

    fun indexOf(byte: Byte, from: Int): Int {
        for (index in from until count) if (array[index] == byte) return index
        return -1
    }

    fun copy(start: Int, end: Int): ByteArray = array.copyOfRange(start, end)
}

/**
 * Splits a `multipart/mixed` body into the bodies of its parts, however the
 * bytes are chunked. Bytes before the first delimiter are a preamble and are
 * dropped; each part's headers are dropped; the body between the headers'
 * blank line and the next delimiter is a part. What a delimiter closes is let
 * go, so the buffer holds one part at most.
 */
class MultipartParser(boundary: String) {
    private val delimiter = ("--$boundary").encodeToByteArray()
    private val buffer = Bytes()

    /** Where the line being read starts. */
    private var lineStart = 0

    /** How far the buffer has been searched for a line end. */
    private var scanned = 0

    /** Whether a delimiter has been read, so the bytes after it are a part. */
    private var inPart = false

    /** Whether the closing delimiter, or the end of the stream, was read. */
    var finished: Boolean = false
        private set

    /** Feeds `chunk[start, end)`; returns the parts completed within it. */
    fun push(chunk: ByteArray, start: Int = 0, end: Int = chunk.size): List<ByteArray> {
        if (finished) return emptyList()
        buffer.append(chunk, start, end)
        val parts = ArrayList<ByteArray>()
        while (true) {
            val newline = buffer.indexOf(LINE_FEED, scanned)
            if (newline < 0) break
            scanned = newline + 1
            var lineEnd = newline
            if (lineEnd > lineStart && buffer[lineEnd - 1] == CARRIAGE_RETURN) lineEnd -= 1
            if (!startsWithDelimiter(lineStart, lineEnd)) {
                if (!inPart) {
                    // A preamble line: nothing keeps it.
                    buffer.drop(scanned)
                    scanned = 0
                }
                lineStart = scanned
                continue
            }
            if (inPart) body(0, lineStart)?.let(parts::add)
            inPart = true
            val after = lineStart + delimiter.size
            if (lineEnd - lineStart >= delimiter.size + 2 && buffer[after] == HYPHEN && buffer[after + 1] == HYPHEN) {
                finished = true
                buffer.clear()
                return parts
            }
            buffer.drop(scanned)
            scanned = 0
            lineStart = 0
        }
        scanned = buffer.count
        return parts
    }

    /** The last part, when the stream ended without a closing delimiter. */
    fun finish(): List<ByteArray> {
        if (finished) return emptyList()
        finished = true
        if (!inPart) return emptyList()
        return listOfNotNull(body(0, buffer.count))
    }

    private fun startsWithDelimiter(start: Int, end: Int): Boolean {
        if (end - start < delimiter.size) return false
        for (offset in delimiter.indices) if (buffer[start + offset] != delimiter[offset]) return false
        return true
    }

    /** A part's body: after its headers' blank line, without the trailing line break. */
    private fun body(start: Int, end: Int): ByteArray? {
        var last = end
        while (last > start && (buffer[last - 1] == LINE_FEED || buffer[last - 1] == CARRIAGE_RETURN)) last -= 1
        if (last == start) return null
        // A part without headers opens with the blank line that ends them.
        if (buffer[start] == LINE_FEED) return buffer.copy(start + 1, last)
        if (buffer[start] == CARRIAGE_RETURN && start + 1 < last && buffer[start + 1] == LINE_FEED) return buffer.copy(start + 2, last)
        var index = start
        while (index < last) {
            if (buffer[index] == LINE_FEED) {
                var next = index + 1
                if (next < last && buffer[next] == CARRIAGE_RETURN) next += 1
                if (next < last && buffer[next] == LINE_FEED) {
                    return if (next + 1 == last) null else buffer.copy(next + 1, last)
                }
            }
            index += 1
        }
        // No headers: the whole part is the body.
        return buffer.copy(start, last)
    }

    companion object {
        /** The `boundary` parameter of a `multipart/` content type, `-` when it names none, or null for another content type. */
        fun boundary(contentType: String): String? {
            if (!contentType.lowercase().startsWith("multipart/")) return null
            for (parameter in contentType.split(';').drop(1)) {
                val trimmed = parameter.trim()
                if (!trimmed.lowercase().startsWith("boundary=")) continue
                return trimmed.substring("boundary=".length).trim('"')
            }
            return "-"
        }
    }
}

/**
 * Splits a `text/event-stream` body into the payloads of its `next` events,
 * however the bytes are chunked: `graphql-sse` in its distinct-connections
 * mode, one response per operation, where a `next` event carries a response
 * payload and `complete` ends the stream. A field is `name: value`, with one
 * space after the colon dropped; the `data` lines of an event join with a
 * line break; a blank line ends an event; a line beginning with a colon is a
 * comment. `id`, `retry` and an event of another name are dropped.
 */
class EventStreamParser {
    private val buffer = Bytes()

    /** How far the buffer has been searched for a line end. */
    private var scanned = 0

    /** The event being read: its name, and its data lines so far. */
    private var event = ""
    private var data: Bytes? = null

    /** Whether the stream's first bytes were seen, where a byte order mark may sit. */
    private var opened = false

    /** Whether `complete` was read, or the stream ended. */
    var finished: Boolean = false
        private set

    /**
     * Feeds `chunk[start, end)`; returns the payloads of the `next` events
     * completed within it. A line ends at a line feed, with a carriage return
     * before it dropped; a byte order mark at the stream's start is skipped.
     */
    fun push(chunk: ByteArray, start: Int = 0, end: Int = chunk.size): List<ByteArray> {
        if (finished) return emptyList()
        buffer.append(chunk, start, end)
        if (!opened && buffer.count >= 3) {
            opened = true
            if (buffer[0] == 0xEF.toByte() && buffer[1] == 0xBB.toByte() && buffer[2] == 0xBF.toByte()) {
                buffer.drop(3)
                scanned = maxOf(0, scanned - 3)
            }
        }
        val payloads = ArrayList<ByteArray>()
        var lineStart = 0
        while (true) {
            val newline = buffer.indexOf(LINE_FEED, scanned)
            if (newline < 0) break
            var lineEnd = newline
            if (lineEnd > lineStart && buffer[lineEnd - 1] == CARRIAGE_RETURN) lineEnd -= 1
            read(lineStart, lineEnd)?.let(payloads::add)
            lineStart = newline + 1
            scanned = lineStart
            if (finished) {
                buffer.clear()
                return payloads
            }
        }
        // The lines read are let go once per chunk, not once per line.
        buffer.drop(lineStart)
        scanned = buffer.count
        return payloads
    }

    /** The event left open when the stream ended without a blank line. */
    fun finish(): List<ByteArray> {
        if (finished) return emptyList()
        val payloads = ArrayList<ByteArray>()
        if (buffer.count > 0) {
            var lineEnd = buffer.count
            if (buffer[lineEnd - 1] == CARRIAGE_RETURN) lineEnd -= 1
            read(0, lineEnd)?.let(payloads::add)
            buffer.clear()
        }
        if (!finished) dispatch()?.let(payloads::add)
        finished = true
        return payloads
    }

    /** One line: a blank line dispatches the event; a comment is dropped; a field sets the event's name or adds a data line. */
    private fun read(start: Int, end: Int): ByteArray? {
        if (start == end) return dispatch()
        if (buffer[start] == COLON) return null
        var colon = start
        while (colon < end && buffer[colon] != COLON) colon += 1
        val field = buffer.copy(start, colon).decodeToString()
        var valueStart = if (colon < end) colon + 1 else end
        if (valueStart < end && buffer[valueStart] == SPACE) valueStart += 1
        when (field) {
            "event" -> event = buffer.copy(valueStart, end).decodeToString()
            "data" -> {
                val lines = data
                if (lines == null) {
                    data = Bytes().also { it.append(buffer.array, valueStart, end) }
                } else {
                    lines.append(byteArrayOf(LINE_FEED), 0, 1)
                    lines.append(buffer.array, valueStart, end)
                }
            }
        }
        return null
    }

    /** The event read so far: a `next` with data is a payload; `complete` ends the stream; anything else is dropped. */
    private fun dispatch(): ByteArray? {
        val name = event
        val lines = data
        event = ""
        data = null
        if (name == "complete") {
            finished = true
            return null
        }
        if (name != "next" || lines == null) return null
        return lines.copy(0, lines.count)
    }

    companion object {
        /** Whether a content type is an event stream's. */
        fun frames(contentType: String): Boolean = contentType.trim().lowercase().startsWith("text/event-stream")
    }
}

/** The errors of a response's `errors` entries, as a request error carries them: messages, dotted paths and extensions. */
internal fun requestErrors(errors: List<ResponseError>): GraphQLErrors =
    GraphQLErrors(errors.map { FieldError(it.message, Ingest.render(it.path ?: emptyList()), it.extensions) })

/**
 * The errors of a body that is a GraphQL response with errors and no data,
 * or with null data, as a server answers a request error; null for any
 * other body, a malformed one among them. Public for a transport over
 * another HTTP client, which reads a response as the built-in one does.
 */
fun requestErrors(body: ByteArray): GraphQLErrors? {
    if (body.isEmpty()) return null
    var errors: List<ResponseError> = emptyList()
    var hasData = false
    try {
        val scanner = Scanner(body)
        scanner.members { key ->
            when (key) {
                "errors" -> errors = scanner.responseErrors()
                "data" -> {
                    hasData = scanner.peek() != 'n'.code
                    scanner.skipValue()
                }
                else -> scanner.skipValue()
            }
        }
    } catch (_: IngestError) {
        return null
    }
    if (hasData || errors.isEmpty()) return null
    return requestErrors(errors)
}

/**
 * Whether a content type's media type is `application/graphql-response+json`,
 * whose body is a GraphQL response whatever the status. Public for a
 * transport over another HTTP client.
 */
fun answersInGraphQLResponse(contentType: String): Boolean =
    contentType.substringBefore(';').trim().lowercase() == "application/graphql-response+json"
