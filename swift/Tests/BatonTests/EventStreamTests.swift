import Baton
import Foundation
import Testing

@Suite("Event stream")
struct EventStreamTests {
    /// The payloads a parser yields for a body fed whole, then finished.
    func payloads(_ body: String) -> [String] {
        var parser = EventStreamParser()
        let pushed = parser.push(Data(body.utf8))
        return (pushed + parser.finish()).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("two next events in one chunk yield two payloads")
    func two_next_events_in_one_chunk_yield_two_payloads() {
        var parser = EventStreamParser()
        let pushed = parser.push(Data("event: next\ndata: {\"a\":1}\n\nevent: next\ndata: {\"a\":2}\n\n".utf8))
        #expect(pushed.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"a":2}"#])
        #expect(parser.finish().isEmpty)
    }

    @Test("an event stream split in two at every byte yields the same payloads as one read whole")
    func an_event_stream_split_at_every_byte_yields_the_same_payloads() {
        let body = Data("event: next\r\ndata: {\"a\":1}\r\n\r\n: keep-alive\n\nevent: next\ndata: {\"a\":\ndata: 2}\n\nevent: complete\ndata:\n\n".utf8)
        let expected = [#"{"a":1}"#, "{\"a\":\n2}"]
        for split in 0...body.count {
            var parser = EventStreamParser()
            var received = parser.push(body[..<split])
            received += parser.push(body[split...])
            received += parser.finish()
            #expect(received.map { String(decoding: $0, as: UTF8.self) } == expected, "split at \(split)")
            #expect(parser.finished)
        }
    }

    @Test("CRLF ends a line as LF does")
    func crlf_ends_a_line_as_lf_does() {
        #expect(payloads("event: next\r\ndata: {\"a\":1}\r\n\r\n") == [#"{"a":1}"#])
    }

    @Test("a comment line and the id and retry fields are ignored")
    func a_comment_and_the_id_and_retry_fields_are_ignored() {
        #expect(payloads(": a comment\nid: 7\nretry: 1000\nevent: next\n: another\ndata: {\"a\":1}\n\n") == [#"{"a":1}"#])
    }

    @Test("the data lines of one event join with a line break")
    func the_data_lines_of_one_event_join_with_a_line_break() {
        #expect(payloads("event: next\ndata: {\"a\":\ndata: 1}\n\n") == ["{\"a\":\n1}"])
    }

    @Test("an event of another name yields nothing")
    func an_event_of_another_name_yields_nothing() {
        #expect(payloads("event: ping\ndata: {\"a\":1}\n\n").isEmpty)
    }

    @Test("a next event without data dispatches nothing")
    func a_next_event_without_data_dispatches_nothing() {
        #expect(payloads("event: next\n\n").isEmpty)
    }

    @Test("complete finishes the stream, drops the bytes after it in its chunk, and later pushes yield nothing")
    func complete_finishes_the_stream_and_drops_what_follows() {
        var parser = EventStreamParser()
        let pushed = parser.push(Data("event: next\ndata: {\"a\":1}\n\nevent: complete\ndata:\n\nevent: next\ndata: {\"a\":2}\n\n".utf8))
        #expect(pushed.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#])
        #expect(parser.finished)
        #expect(parser.push(Data("event: next\ndata: {\"a\":3}\n\n".utf8)).isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test("a final next event without a trailing blank line is yielded by finish")
    func a_final_next_event_without_a_blank_line_is_yielded_by_finish() {
        var parser = EventStreamParser()
        #expect(parser.push(Data("event: next\ndata: {\"a\":1}".utf8)).isEmpty)
        #expect(parser.finish().map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#])
        #expect(parser.finished)

        var terminated = EventStreamParser()
        #expect(terminated.push(Data("event: next\ndata: {\"a\":2}\n".utf8)).isEmpty)
        #expect(terminated.finish().map { String(decoding: $0, as: UTF8.self) } == [#"{"a":2}"#])
    }

    @Test("a value without a space after the colon is kept whole, and one space after it is dropped")
    func one_space_after_the_colon_is_dropped() {
        #expect(payloads("event:next\ndata:value\n\n") == ["value"])
        #expect(payloads("event: next\ndata: value\n\n") == ["value"])
        #expect(payloads("event: next\ndata:  value\n\n") == [" value"])
    }

    @Test("an event stream's content type frames events, with parameters, and another does not")
    func an_event_streams_content_type_frames_events() {
        #expect(EventStreamParser.frames("text/event-stream"))
        #expect(EventStreamParser.frames("text/event-stream; charset=utf-8"))
        #expect(!EventStreamParser.frames("application/json"))
        #expect(!EventStreamParser.frames("multipart/mixed; boundary=\"-\""))
    }
}
