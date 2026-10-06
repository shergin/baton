import Baton
import Foundation

/// The exchange an app owns around Baton's one verb: the few dozen lines a
/// production endpoint needs and the library does not ship, since they
/// compose what it has. Credentials are the base transport's own, read per
/// attempt; this adds one replay of an authorization challenge, a bounded
/// retry with backoff over the outcomes a retry can mend, a deadline that
/// spans every attempt, and the rule that a mutation is never sent twice,
/// since the server may have received it. Copy it, and change the numbers
/// to the endpoint's.
public struct Exchange: Transport {
    /// The transport this wraps, which holds the endpoint and its credentials.
    public let base: any Transport
    /// Called once per request on a 401, before the one replay; the base
    /// transport's `credentials` closure then reads the renewed token.
    public let challenged: @Sendable () async throws -> Void
    /// How many times a query or a subscription is sent, at most; the
    /// replay of a challenge is not counted.
    public let attempts: Int
    /// The whole exchange, across every attempt and the waits between them.
    public let deadline: Duration
    /// The first wait before a retry, doubled at each further one.
    public let step: Duration

    public init(
        base: any Transport,
        attempts: Int = 3,
        deadline: Duration = .seconds(30),
        step: Duration = .milliseconds(500),
        challenged: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.base = base
        self.attempts = attempts
        self.deadline = deadline
        self.step = step
        self.challenged = challenged
    }

    /// Whether a retry may mend a failure: a 5xx status, or a connection
    /// that was lost or timed out. A 4xx other than 401, a request error and
    /// a malformed response would repeat.
    public static func mends(_ error: any Error) -> Bool {
        if let transport = error as? TransportError { return (500..<600).contains(transport.statusCode) }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(url.code)
        }
        return false
    }

    public func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let started = ContinuousClock.now
                var replayed = false
                var retries = 0
                while true {
                    var delivered = false
                    do {
                        for try await payload in base.send(request) {
                            delivered = true
                            continuation.yield(payload)
                        }
                        continuation.finish()
                        return
                    } catch {
                        // A stream that delivered is not sent again: the caller
                        // has part of the answer, and a stream resumes nothing.
                        if delivered {
                            continuation.finish(throwing: error)
                            return
                        }
                        // A 401 was refused before execution, so even a
                        // mutation is sent once more, with the renewed token.
                        if let transport = error as? TransportError, transport.statusCode == 401, !replayed {
                            replayed = true
                            do {
                                try await challenged()
                            } catch {
                                continuation.finish(throwing: error)
                                return
                            }
                            continue
                        }
                        // A mutation is never sent twice: the server may have
                        // received it.
                        guard request.kind != .mutation, Self.mends(error), retries + 1 < attempts else {
                            continuation.finish(throwing: error)
                            return
                        }
                        // The wait doubles and is jittered; the deadline
                        // covers the wait as well as the attempt.
                        let pause = step * (1 << min(retries, 10))
                        let wait = pause / 2 + pause / 2 * Double.random(in: 0...1)
                        guard ContinuousClock.now + wait < started + deadline else {
                            continuation.finish(throwing: error)
                            return
                        }
                        do {
                            try await Task.sleep(for: wait)
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                        retries += 1
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
