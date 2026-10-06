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
    /// `execute` appends under, from any thread.
    public var requests: [Request] { lock.withLock { sent } }

    public var requestCount: Int { lock.withLock { sent.count } }

    public func execute(_ request: Request) async throws -> Data {
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
