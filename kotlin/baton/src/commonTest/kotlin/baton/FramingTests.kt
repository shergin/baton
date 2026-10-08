package baton

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The framings the built-in transports read a response through, as the Swift runtime's tests hold them. */
class FramingTests {
    /** The payloads an event-stream parser yields for a body fed whole, then finished. */
    private fun events(body: String): List<String> {
        val parser = EventStreamParser()
        val pushed = parser.push(body.encodeToByteArray())
        return (pushed + parser.finish()).map { it.decodeToString() }
    }

    @Test
    fun `the multipart parser yields each part's body however the bytes are chunked, and drops a preamble`() {
        val body = "a preamble, which is no part\r\n---\r\nContent-Type: application/json\r\n\r\n{\"data\":{\"a\":1},\"hasNext\":true}\r\n" +
            "---\r\nContent-Type: application/json\r\n\r\n{\"incremental\":[],\"hasNext\":false}\r\n-----\r\n"
        val bytes = body.encodeToByteArray()
        for (chunk in listOf(1, 7, 64, bytes.size)) {
            val parser = MultipartParser("-")
            val parts = ArrayList<ByteArray>()
            var offset = 0
            while (offset < bytes.size) {
                val end = minOf(offset + chunk, bytes.size)
                parts += parser.push(bytes, offset, end)
                offset = end
            }
            parts += parser.finish()
            assertEquals(
                listOf("{\"data\":{\"a\":1},\"hasNext\":true}", "{\"incremental\":[],\"hasNext\":false}"),
                parts.map { it.decodeToString() },
                "chunks of $chunk",
            )
            assertTrue(parser.finished)
        }
    }

    @Test
    fun `a multipart part without headers is its body, and a stream ended without the closing delimiter yields its last part`() {
        val parser = MultipartParser("-")
        val parts = parser.push("\r\n---\r\n\r\n{\"data\":{},\"hasNext\":true}\r\n---\r\n\r\n{\"hasNext\":false}".encodeToByteArray()) + parser.finish()
        assertEquals(listOf("{\"data\":{},\"hasNext\":true}", "{\"hasNext\":false}"), parts.map { it.decodeToString() })
    }

    @Test
    fun `a multipart content type names its boundary, quoted or not, and is the hyphen without one`() {
        assertEquals("graphql", MultipartParser.boundary("multipart/mixed; boundary=\"graphql\"; deferSpec=20220824"))
        assertEquals("graphql", MultipartParser.boundary("multipart/mixed;boundary=graphql"))
        assertEquals("-", MultipartParser.boundary("multipart/mixed"))
        assertNull(MultipartParser.boundary("application/json"))
    }

    @Test
    fun `two next events in one chunk yield two payloads`() {
        val parser = EventStreamParser()
        val pushed = parser.push("event: next\ndata: {\"a\":1}\n\nevent: next\ndata: {\"a\":2}\n\n".encodeToByteArray())
        assertEquals(listOf("{\"a\":1}", "{\"a\":2}"), pushed.map { it.decodeToString() })
        assertTrue(parser.finish().isEmpty())
    }

    @Test
    fun `an event stream split in two at every byte yields the same payloads as one read whole`() {
        val body = "event: next\r\ndata: {\"a\":1}\r\n\r\n: keep-alive\n\nevent: next\ndata: {\"a\":\ndata: 2}\n\nevent: complete\ndata:\n\n".encodeToByteArray()
        val expected = listOf("{\"a\":1}", "{\"a\":\n2}")
        for (split in 0..body.size) {
            val parser = EventStreamParser()
            val received = parser.push(body, 0, split) + parser.push(body, split, body.size) + parser.finish()
            assertEquals(expected, received.map { it.decodeToString() }, "split at $split")
            assertTrue(parser.finished)
        }
    }

    @Test
    fun `an event stream fed a byte at a time skips a byte order mark at its start`() {
        val body = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "event: next\ndata: {\"a\":1}\n\n".encodeToByteArray()
        val parser = EventStreamParser()
        val received = body.indices.flatMap { parser.push(body, it, it + 1) }
        assertEquals(listOf("{\"a\":1}"), received.map { it.decodeToString() })
    }

    @Test
    fun `CRLF ends a line as LF does`() {
        assertEquals(listOf("{\"a\":1}"), events("event: next\r\ndata: {\"a\":1}\r\n\r\n"))
    }

    @Test
    fun `a comment line and the id and retry fields are ignored`() {
        assertEquals(listOf("{\"a\":1}"), events(": a comment\nid: 7\nretry: 1000\nevent: next\n: another\ndata: {\"a\":1}\n\n"))
    }

    @Test
    fun `the data lines of one event join with a line break`() {
        assertEquals(listOf("{\"a\":\n1}"), events("event: next\ndata: {\"a\":\ndata: 1}\n\n"))
    }

    @Test
    fun `an event of another name yields nothing`() {
        assertTrue(events("event: ping\ndata: {\"a\":1}\n\n").isEmpty())
    }

    @Test
    fun `a next event without data dispatches nothing`() {
        assertTrue(events("event: next\n\n").isEmpty())
    }

    @Test
    fun `complete finishes the stream, drops the bytes after it in its chunk, and later pushes yield nothing`() {
        val parser = EventStreamParser()
        val pushed = parser.push("event: next\ndata: {\"a\":1}\n\nevent: complete\ndata:\n\nevent: next\ndata: {\"a\":2}\n\n".encodeToByteArray())
        assertEquals(listOf("{\"a\":1}"), pushed.map { it.decodeToString() })
        assertTrue(parser.finished)
        assertTrue(parser.push("event: next\ndata: {\"a\":3}\n\n".encodeToByteArray()).isEmpty())
        assertTrue(parser.finish().isEmpty())
    }

    @Test
    fun `a final next event without a trailing blank line is yielded by finish`() {
        val parser = EventStreamParser()
        assertTrue(parser.push("event: next\ndata: {\"a\":1}".encodeToByteArray()).isEmpty())
        assertEquals(listOf("{\"a\":1}"), parser.finish().map { it.decodeToString() })
        assertTrue(parser.finished)

        val terminated = EventStreamParser()
        assertTrue(terminated.push("event: next\ndata: {\"a\":2}\n".encodeToByteArray()).isEmpty())
        assertEquals(listOf("{\"a\":2}"), terminated.finish().map { it.decodeToString() })
    }

    @Test
    fun `a value without a space after the colon is kept whole, and one space after it is dropped`() {
        assertEquals(listOf("value"), events("event:next\ndata:value\n\n"))
        assertEquals(listOf("value"), events("event: next\ndata: value\n\n"))
        assertEquals(listOf(" value"), events("event: next\ndata:  value\n\n"))
    }

    @Test
    fun `an event stream's content type frames events, with parameters, and another does not`() {
        assertTrue(EventStreamParser.frames("text/event-stream"))
        assertTrue(EventStreamParser.frames("text/event-stream; charset=utf-8"))
        assertFalse(EventStreamParser.frames("application/json"))
        assertFalse(EventStreamParser.frames("multipart/mixed; boundary=\"-\""))
    }

    @Test
    fun `a body of errors and no data, or null data, is a request error with its paths and extensions, and any other body is not`() {
        val refused = requestErrors(
            "{\"errors\":[{\"message\":\"Cannot query field\",\"path\":[\"a\",0],\"extensions\":{\"code\":\"GRAPHQL_VALIDATION_FAILED\"}}],\"data\":null}".encodeToByteArray(),
        )
        assertEquals(listOf("Cannot query field"), refused?.messages)
        assertEquals(listOf("a.0"), refused?.errors?.map { it.path })
        assertEquals(Variable.Object(mapOf("code" to Variable.String("GRAPHQL_VALIDATION_FAILED"))), refused?.errors?.single()?.extensions)
        assertNull(requestErrors("{\"errors\":[{\"message\":\"partial\"}],\"data\":{\"a\":1}}".encodeToByteArray()))
        assertNull(requestErrors("{\"data\":null}".encodeToByteArray()))
        assertNull(requestErrors("<html>down</html>".encodeToByteArray()))
        assertNull(requestErrors(ByteArray(0)))
    }
}
