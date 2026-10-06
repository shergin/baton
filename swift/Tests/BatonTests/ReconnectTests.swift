@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

/// Serialized because the backoff's base is one value for the process: each
/// test shortens it and restores it.
@MainActor
@Suite("Reconnection", .serialized, .timeLimit(.minutes(1)))
struct ReconnectTests {
    /// A subscription transport the test drives: each `send` opens a stream
    /// the test yields events into, fails, or completes, and records whether
    /// the handle cancelled it.
    final class Script: Transport, @unchecked Sendable {
        private(set) var continuations: [AsyncThrowingStream<Data, any Error>.Continuation] = []
        private(set) var terminated: [Bool] = []

        var sends: Int { continuations.count }

        func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let index = continuations.count
            continuations.append(continuation)
            terminated.append(false)
            continuation.onTermination = { _ in self.terminated[index] = true }
            return stream
        }

        func deliver(_ data: Data) { continuations.last?.yield(data) }

        func fail() {
            continuations.last?.finish(throwing: TransportError(statusCode: 502, body: "the stream broke"))
        }

        func complete() { continuations.last?.finish() }

        /// Ends the stream as a server's refusal of the operation: errors and
        /// no data.
        func refuse() { continuations.last?.finish(throwing: GraphQLErrors(messages: ["bad subscription"])) }
    }

    /// An environment over the script and a subscription handle in it. The
    /// handle holds its environment weakly, so the test keeps it alive.
    func subscription(_ script: Script, line: Int = #line) -> (Environment, SubscriptionHandle<TestNoteAdded>) {
        let environment = Environment(transport: SilentTransport(), subscriptions: script)
        environment.store.reportMissing = nil
        let handle = environment.subscriptionHandle(for: TestNoteAdded(characterId: "reconnect-\(line)", connections: []))
        return (environment, handle)
    }

    /// Runs `body` with the backoff's base set, and restores it.
    func withBase(_ base: Duration, _ body: () async throws -> Void) async rethrows {
        let saved = SubscriptionBackoff.base
        SubscriptionBackoff.base = base
        defer { SubscriptionBackoff.base = saved }
        try await body()
    }

    /// Keeps the main actor busy without suspending, so a task that wakes
    /// meanwhile is queued behind the caller.
    func hold(for duration: Duration) {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {}
    }

    /// The instant a waiting stream opens again, or nil for another state.
    func waitingUntil(_ stream: Baton.Stream) -> ContinuousClock.Instant? {
        guard case .waiting(let instant) = stream else { return nil }
        return instant
    }

    func isConnecting(_ stream: Baton.Stream) -> Bool {
        guard case .connecting = stream else { return false }
        return true
    }

    func isOpen(_ stream: Baton.Stream) -> Bool {
        guard case .open = stream else { return false }
        return true
    }

    func isIdle(_ stream: Baton.Stream) -> Bool {
        guard case .idle = stream else { return false }
        return true
    }

    @Test("a stream that fails once waits with the failure as its error, then connects and opens again, counting one resumption, and its events go on with the error cleared")
    func a_stream_that_fails_once_reconnects_and_counts_one_resumption() async {
        await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            #expect(isConnecting(live.stream))
            await until { script.sends == 1 }
            script.deliver(fixture("note-added-1"))
            await until { live.events == 1 }
            #expect(isOpen(live.stream))

            script.fail()
            await until { waitingUntil(live.stream) != nil }
            #expect(live.error is TransportError, "the failure the stream waits on is the handle's error")
            #expect(!live.isActive)
            #expect(live.resumptions == 0)

            await until { script.sends == 2 }
            #expect(isConnecting(live.stream))
            #expect(live.resumptions == 1)
            #expect(live.error == nil)
            script.deliver(fixture("note-added-2"))
            await until { live.events == 2 }
            #expect(isOpen(live.stream))
            #expect(live.error == nil)
            _ = consume retention
        }
    }

    @Test("a stream the server completes ends with no failure and is not opened again")
    func a_stream_the_server_completes_ends_and_does_not_reconnect() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.deliver(fixture("note-added-1"))
            await until { live.events == 1 }
            script.complete()
            await until { !live.isActive }
            guard case .ended(nil) = live.stream else {
                Issue.record("expected the stream ended with no failure, got \(live.stream)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(script.sends == 1)
            #expect(live.resumptions == 0)
            #expect(live.error == nil)
            _ = consume retention
        }
    }

    @Test("a retry during the wait opens the stream again at once, before the backoff could elapse")
    func a_retry_during_the_wait_reconnects_at_once() async {
        await withBase(.seconds(5)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            let start = ContinuousClock.now
            live.retry()
            #expect(isConnecting(live.stream))
            await until(timeout: .seconds(1)) { script.sends == 2 }
            #expect(ContinuousClock.now - start < .milliseconds(2500), "the shortest wait at this base is half of it")
            _ = consume retention
        }
    }

    @Test("a release during the wait stops the handle: the stream is idle and is not opened again")
    func a_release_during_the_wait_stops_the_handle() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            _ = consume retention
            #expect(isIdle(live.stream))
            try await Task.sleep(for: .milliseconds(100))
            #expect(script.sends == 1)
            #expect(isIdle(live.stream))
            #expect(live.resumptions == 0)
        }
    }

    @Test("the environment's end during the wait ends the stream with the environment's failure and does not open it again")
    func the_environment_ending_during_the_wait_ends_the_stream() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            await environment.end()
            guard case .ended(.environment(.gone)) = live.stream else {
                Issue.record("expected the stream ended by the environment, got \(live.stream)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(script.sends == 1)
            guard case .ended(.environment(.gone)) = live.stream else {
                Issue.record("expected the stream still ended by the environment, got \(live.stream)")
                return
            }
            _ = consume retention
        }
    }

    @Test("the instant a stream waits until lies between half and the whole of the first step from the failure")
    func the_first_wait_lies_between_half_and_the_whole_of_the_step() async throws {
        let base = Duration.milliseconds(20)
        try await withBase(base) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            let before = ContinuousClock.now
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            let after = ContinuousClock.now
            let instant = try #require(waitingUntil(live.stream))
            #expect(instant >= before + base / 2)
            #expect(instant <= after + base)
            _ = consume retention
        }
    }

    @Test("a second failure in a row waits a doubled step, and an event in between resets the step")
    func consecutive_failures_double_the_step_and_an_event_resets_it() async throws {
        let base = Duration.milliseconds(20)
        try await withBase(base) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { script.sends == 2 }

            // The second failure with no event since: a step of twice the base.
            let before = ContinuousClock.now
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            let after = ContinuousClock.now
            let doubled = try #require(waitingUntil(live.stream))
            #expect(doubled >= before + base, "the second wait is at least half of a doubled step")
            #expect(doubled <= after + base * 2)
            await until { script.sends == 3 }
            #expect(live.resumptions == 2)

            // An event resets the step: the next failure waits the first one.
            script.deliver(fixture("note-added-1"))
            await until { live.events == 1 }
            let beforeReset = ContinuousClock.now
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            let afterReset = ContinuousClock.now
            let reset = try #require(waitingUntil(live.stream))
            #expect(reset >= beforeReset + base / 2)
            #expect(reset <= afterReset + base, "an event resets the step to the base")
            _ = consume retention
        }
    }

    @Test("an inactive environment closes a retained stream and keeps the retention, and activity opens it again as a resumption")
    func inactivity_parks_a_retained_stream_and_activity_resumes_it() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.deliver(fixture("note-added-1"))
            await until { live.events == 1 }
            let held = live.retainCount

            environment.isActive = false
            #expect(isIdle(live.stream))
            #expect(live.retainCount == held)
            await until { script.terminated[0] }
            try await Task.sleep(for: .milliseconds(100))
            #expect(script.sends == 1, "a parked stream does not reconnect")

            environment.isActive = true
            #expect(isConnecting(live.stream))
            #expect(live.resumptions == 1)
            await until { script.sends == 2 }
            script.deliver(fixture("note-added-2"))
            await until { live.events == 2 }
            #expect(isOpen(live.stream))
            _ = consume retention
        }
    }

    @Test("the environment's activity does nothing to a query handle nor to a subscription no one retains")
    func activity_leaves_queries_and_unretained_subscriptions_alone() async throws {
        try await withBase(.milliseconds(20)) {
            let transport = RecordedTransport([TestProfileQuery.name: fixture("character-errors")])
            let script = Script()
            let environment = Environment(transport: transport, subscriptions: script)
            environment.store.reportMissing = nil
            let query = environment.handle(for: TestProfileQuery(id: "1"))
            let retention = query.retain()
            await query.settle()
            guard case .ready = query.phase else {
                Issue.record("expected .ready, got \(query.phase)")
                return
            }
            let unretained = environment.subscriptionHandle(for: TestNoteAdded(characterId: "reconnect-\(#line)", connections: []))

            environment.isActive = false
            environment.isActive = true
            try await Task.sleep(for: .milliseconds(100))

            guard case .ready = query.phase else {
                Issue.record("expected .ready still, got \(query.phase)")
                return
            }
            #expect(transport.requestCount == 1)
            #expect(isIdle(unretained.stream))
            #expect(unretained.resumptions == 0)
            #expect(script.sends == 0)
            _ = consume retention
        }
    }

    @Test("parking during the wait cancels it, and resuming opens the stream again")
    func parking_during_the_wait_cancels_it_and_resuming_reconnects() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { waitingUntil(live.stream) != nil }

            environment.isActive = false
            #expect(isIdle(live.stream))
            try await Task.sleep(for: .milliseconds(100))
            #expect(script.sends == 1, "a parked wait does not reconnect")
            #expect(live.resumptions == 0)

            environment.isActive = true
            #expect(isConnecting(live.stream))
            await until { script.sends == 2 }
            #expect(live.resumptions == 1)
            _ = consume retention
        }
    }

    @Test("a retry that lands after the wait elapsed but before the waiting task resumed keeps the new stream: the old task leaves the state to the retry")
    func a_retry_after_the_wait_elapsed_keeps_the_new_stream() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            // Holds the main actor past the longest wait, so the sleep ends
            // and the waiting task is queued behind this test, not cancelled.
            hold(for: .milliseconds(60))
            live.retry()
            #expect(isConnecting(live.stream))
            await until { script.sends == 2 }
            for _ in 0..<10 { await Task.yield() }
            #expect(isConnecting(live.stream), "the old task does not overwrite the retried stream's state")
            script.deliver(fixture("note-added-1"))
            await until(timeout: .milliseconds(500)) { live.events == 1 }
            _ = consume retention
            try await Task.sleep(for: .milliseconds(50))
            #expect(script.terminated.allSatisfy { $0 }, "a release cancels every stream the handle opened")
            #expect(script.sends == 2)
        }
    }

    @Test("the environment's end that lands after the wait elapsed but before the waiting task resumed leaves the stream ended by the environment")
    func an_end_after_the_wait_elapsed_leaves_the_stream_ended() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.fail()
            await until { waitingUntil(live.stream) != nil }
            hold(for: .milliseconds(60))
            await environment.end()
            for _ in 0..<10 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(50))
            guard case .ended(.environment(.gone)) = live.stream else {
                Issue.record("expected the stream ended by the environment, got \(live.stream)")
                return
            }
            #expect(script.sends == 1)
            _ = consume retention
        }
    }

    @Test("a handle retained while the environment is inactive stays idle and sends nothing, and activity opens it as a resumption")
    func a_handle_retained_while_inactive_waits_parked_for_activity() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            environment.isActive = false
            let retention = live.retain()
            #expect(isIdle(live.stream))
            try await Task.sleep(for: .milliseconds(100))
            #expect(script.sends == 0, "an inactive environment opens no stream")
            #expect(isIdle(live.stream))

            environment.isActive = true
            #expect(isConnecting(live.stream))
            await until { script.sends == 1 }
            #expect(live.resumptions == 1)
            script.deliver(fixture("note-added-1"))
            await until { live.events == 1 }
            #expect(isOpen(live.stream))
            try await Task.sleep(for: .milliseconds(50))
            #expect(script.sends == 1)
            _ = consume retention
        }
    }

    @Test("a stream that fails while the environment is inactive parks without a wait, and activity opens it again as a resumption")
    func a_stream_that_fails_while_inactive_parks_instead_of_waiting() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.deliver(fixture("note-added-1"))
            await until { live.events == 1 }
            // A failure that reaches the stream after the environment went
            // inactive, as a socket the system closed in the background.
            let failing = try #require(script.continuations.first)
            environment.isActive = false
            failing.finish(throwing: TransportError(statusCode: 0, body: "the socket closed"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(isIdle(live.stream), "an inactive environment parks, not waits")
            #expect(script.sends == 1, "no backoff reopens a parked stream")
            #expect(live.resumptions == 0)

            environment.isActive = true
            #expect(isConnecting(live.stream))
            await until { script.sends == 2 }
            #expect(live.resumptions == 1)
            _ = consume retention
        }
    }

    @Test("a stream the server refuses with a request error ends with that failure and is not opened again, and a retry opens it")
    func a_request_error_ends_the_stream_and_a_retry_reopens_it() async throws {
        try await withBase(.milliseconds(20)) {
            let script = Script()
            let (environment, live) = subscription(script)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { script.sends == 1 }
            script.refuse()
            await until { !live.isActive }
            guard case .ended(.request(let errors)?) = live.stream else {
                Issue.record("expected the stream ended by a request failure, got \(live.stream)")
                return
            }
            #expect(errors.messages == ["bad subscription"])
            #expect((live.error as? GraphQLErrors)?.messages == ["bad subscription"])
            try await Task.sleep(for: .milliseconds(150))
            #expect(script.sends == 1, "a refusal is not reconnected, however many steps pass")
            #expect(live.resumptions == 0)

            live.retry()
            #expect(isConnecting(live.stream))
            await until { script.sends == 2 }
            #expect(live.error == nil)
            _ = consume retention
        }
    }
}
