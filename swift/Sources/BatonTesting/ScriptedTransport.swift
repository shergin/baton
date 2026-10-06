import Baton
import Foundation

/// A transport an app's tests script: it answers operations from fixtures
/// by name or through a responder, holds a mutation until the test replies
/// or refuses, drives a subscription's events by hand, and keeps every
/// request it was sent. Not a mock: it is a transport like any other, and
/// nothing behind it can tell.
///
/// An operation with no answer scripted fails with a `TransportError` of
/// status 0 that says so; a mutation with none is held instead, since a
/// test usually wants the window between an optimistic apply and the
/// server's answer.
public final class ScriptedTransport: Transport, @unchecked Sendable {
    /// A request held until the test answers it.
    public struct Held: Sendable {
        public let request: Request
        /// Which send this is, since two requests may be equal.
        let token: UInt64
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

        init(request: Request, token: UInt64, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.request = request
            self.token = token
            self.continuation = continuation
        }

        /// Answers the request with one payload and ends its stream.
        public func respond(_ data: Data) {
            continuation.yield(data)
            continuation.finish()
        }

        /// Fails the request.
        public func refuse(_ error: any Error) {
            continuation.finish(throwing: error)
        }
    }

    /// A stream the test drives: a subscription's events, or the parts of a
    /// deferred response.
    public struct Driven: Sendable {
        public let request: Request
        /// Which send this is, since two requests may be equal.
        let token: UInt64
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

        init(request: Request, token: UInt64, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.request = request
            self.token = token
            self.continuation = continuation
        }

        /// Delivers one payload.
        public func send(_ data: Data) { continuation.yield(data) }

        /// Ends the stream, as a server completing it does.
        public func complete() { continuation.finish() }

        /// Ends the stream with a failure.
        public func fail(_ error: any Error) { continuation.finish(throwing: error) }
    }

    private let lock = NSLock()
    private var answers: [String: Data] = [:]
    private var heldNames: Set<String> = []
    private var drivenNames: Set<String> = []
    private let responder: (@Sendable (Request) -> Data?)?
    private let holdsMutations: Bool
    private var sent: [Request] = []
    private var waiting: [Held] = []
    private var driving: [Driven] = []
    /// Numbers each send, so a stream's end forgets its own entry and not an
    /// equal request's.
    private var tokens: UInt64 = 0

    /// Answers from `answers` by operation name; holds mutations by default.
    public init(_ answers: [String: Data] = [:], holdsMutations: Bool = true) {
        self.answers = answers
        self.holdsMutations = holdsMutations
        responder = nil
    }

    /// Answers through `responder`, which sees the whole request; a request
    /// it answers nil for falls back to the scripted answers.
    public init(holdsMutations: Bool = true, responder: @escaping @Sendable (Request) -> Data?) {
        self.holdsMutations = holdsMutations
        self.responder = responder
    }

    /// Scripts the answer to every request of the operation.
    public func answer(_ operationName: String, with data: Data) {
        lock.withLock { answers[operationName] = data }
    }

    /// Holds every request of the operation until the test answers it.
    public func hold(_ operationName: String) {
        lock.withLock { _ = heldNames.insert(operationName) }
    }

    /// Lets the test drive every request of the operation as a stream.
    public func drive(_ operationName: String) {
        lock.withLock { _ = drivenNames.insert(operationName) }
    }

    /// The requests held, oldest first; answering one takes it off the list.
    public var held: [Held] { lock.withLock { waiting } }

    /// The streams the test drives, oldest first.
    public var driven: [Driven] { lock.withLock { driving } }

    /// The requests the transport was sent, in the order of the calls.
    public var requests: [Request] { lock.withLock { sent } }

    public var requestCount: Int { lock.withLock { sent.count } }

    /// The requests of one kind.
    public func requests(of kind: Request.Kind) -> [Request] {
        lock.withLock { sent.filter { $0.kind == kind } }
    }

    public func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        lock.withLock {
            sent.append(request)
            tokens += 1
            let token = tokens
            if drivenNames.contains(request.operationName) || (request.kind == .subscription && answers[request.operationName] == nil && responder == nil) {
                driving.append(Driven(request: request, token: token, continuation: continuation))
                continuation.onTermination = { [weak self] _ in self?.forget(driven: token) }
                return
            }
            if let responder, let data = responder(request) {
                continuation.yield(data)
                continuation.finish()
                return
            }
            if let data = answers[request.operationName] {
                continuation.yield(data)
                continuation.finish()
                return
            }
            if heldNames.contains(request.operationName) || (request.kind == .mutation && holdsMutations) {
                waiting.append(Held(request: request, token: token, continuation: continuation))
                continuation.onTermination = { [weak self] _ in self?.forget(held: token) }
                return
            }
            continuation.finish(throwing: TransportError(statusCode: 0, body: "no answer scripted for \(request.operationName)"))
        }
        return stream
    }

    private func forget(held token: UInt64) {
        lock.withLock { waiting.removeAll { $0.token == token } }
    }

    private func forget(driven token: UInt64) {
        lock.withLock { driving.removeAll { $0.token == token } }
    }
}
