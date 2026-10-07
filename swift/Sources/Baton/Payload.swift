import Foundation

/// Bytes in a response's shape: the one thing the door from outside the
/// store takes. A server's response is one, as the transport yields it; an
/// optimistic response is one, as the generated builders render it; a
/// payload committed by hand, a REST response, a socket's tick, a preview's
/// fixture, a test's seed, is one. Relay's word, from `commitPayload`. A
/// payload keeps a scalar's text as written: the ingest reads it, and
/// nothing is decoded into a value on the way.
public struct Payload: Sendable, Hashable {
    /// The response's bytes: an object with `data`, as a server writes it.
    public let bytes: Data

    public init(_ bytes: Data) {
        self.bytes = bytes
    }

    /// A response written as JSON text.
    public init(json: String) {
        bytes = Data(json.utf8)
    }

    /// A response whose `data` is the value: what the generated builders of
    /// an optimistic response render.
    @_spi(Generated) public init(data: Variable) {
        self.init(json: "{\"data\":" + data.json + "}")
    }
}
