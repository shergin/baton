import Baton
import Foundation

/// Serves recorded responses by operation name, or through a responder that
/// sees the whole request; for tests, previews and benchmarks.
public final class RecordedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: Data]
    private let responder: (@Sendable (Request) -> Data?)?
    private var sent: [Request] = []

    public init(_ responses: [String: Data] = [:]) {
        self.responses = responses
        responder = nil
    }

    public init(responder: @escaping @Sendable (Request) -> Data?) {
        responses = [:]
        self.responder = responder
    }

    public func record(_ operationName: String, _ data: Data) {
        lock.withLock { responses[operationName] = data }
    }

    /// The requests the transport was sent, in order. Read under the lock
    /// `send` appends under, from any thread.
    public var requests: [Request] { lock.withLock { sent } }

    public var requestCount: Int { lock.withLock { sent.count } }

    /// Records the request as it is sent, so the order of `requests` is the
    /// order of the calls, and answers on the stream.
    public func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        let answer = Result { try self.answer(request) }
        return Self.once { try answer.get() }
    }

    private func answer(_ request: Request) throws -> Data {
        try lock.withLock {
            sent.append(request)
            if let responder, let data = responder(request) { return data }
            guard let data = responses[request.operationName] else {
                throw TransportError(statusCode: 0, body: "no recorded response for \(request.operationName)")
            }
            return data
        }
    }
}
