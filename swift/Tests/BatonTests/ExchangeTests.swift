@_spi(Generated) import Baton
import BatonTesting
import Exchange
import Foundation
import Testing

@MainActor
@Suite("Exchange", .timeLimit(.minutes(1)))
struct ExchangeTests {
    let query = Request(operationName: TestHeaderQuery.name, kind: .query, document: .text("query TestHeaderQuery { a }"), variables: .none)
    let mutation = Request(operationName: TestSetFavorite.name, kind: .mutation, document: .text("mutation TestSetFavorite { a }"), variables: .none)
    let answer = fixture("character-header-5")

    /// The status of the transport error `task` failed with, or nil when it
    /// returned or failed with something else.
    func status(of task: Task<Data, any Error>) async -> Int? {
        do {
            _ = try await task.value
            return nil
        } catch let error as TransportError {
            return error.statusCode
        } catch {
            return nil
        }
    }

    /// Waits until `transport` was sent `count` requests and holds one, then
    /// returns it.
    func held(_ transport: ScriptedTransport, sent count: Int) async throws -> ScriptedTransport.Held {
        await until { transport.requestCount == count && transport.held.count == 1 }
        return try #require(transport.held.first)
    }

    @Test("a 401 then a success over URLSessionTransport is sent twice, challenged once, and the second attempt carries the token the challenge renewed")
    func a_challenge_is_replayed_once_with_the_renewed_token() async throws {
        let key = UUID().uuidString
        let token = Token("stale")
        let challenges = Counter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChallengeServer.self]
        let base = URLSessionTransport(
            url: URL(string: "https://stub.invalid/graphql")!,
            headers: ["X-Stub-Key": key],
            credentials: { ["Authorization": "Bearer \(token.value)"] },
            session: URLSession(configuration: configuration)
        )
        let exchange = Exchange(base: base, step: .milliseconds(1)) {
            challenges.increment()
            token.value = "renewed"
        }

        let payload = try await exchange.payload(query)
        #expect(payload == answer)
        #expect(challenges.value == 1)
        #expect(ChallengeServer.authorizations(for: key) == ["Bearer stale", "Bearer renewed"])
    }

    @Test("a second 401 after the replay fails the request with that 401, sent twice and challenged once")
    func a_second_challenge_fails_the_request() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let challenges = Counter()
        let exchange = Exchange(base: transport, step: .milliseconds(1)) { challenges.increment() }
        let task = Task { try await exchange.payload(query) }

        try await held(transport, sent: 1).refuse(TransportError(statusCode: 401, body: "expired"))
        try await held(transport, sent: 2).refuse(TransportError(statusCode: 401, body: "still expired"))
        #expect(await status(of: task) == 401)
        #expect(transport.requestCount == 2)
        #expect(challenges.value == 1)
    }

    @Test("a query refused with a 503 and then answered is sent twice and delivers the answer")
    func a_503_then_a_200_is_sent_twice_and_delivers() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let exchange = Exchange(base: transport, step: .milliseconds(1))
        let task = Task { try await exchange.payload(query) }

        try await held(transport, sent: 1).refuse(TransportError(statusCode: 503, body: "down"))
        try await held(transport, sent: 2).respond(answer)
        #expect(try await task.value == answer)
        #expect(transport.requestCount == 2)
    }

    @Test("a query refused with a 503 every time is sent as many times as attempts allows and fails with the 503")
    func attempts_bound_the_sends() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let exchange = Exchange(base: transport, attempts: 3, step: .milliseconds(1))
        let task = Task { try await exchange.payload(query) }

        for count in 1...3 {
            try await held(transport, sent: count).refuse(TransportError(statusCode: 503, body: "down \(count)"))
        }
        #expect(await status(of: task) == 503)
        #expect(transport.requestCount == 3)
        #expect(transport.held.isEmpty)
    }

    @Test("a 503 whose backoff would pass the deadline fails with the 503 at once, sent once")
    func a_deadline_that_expires_during_the_backoff_fails_without_waiting() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let exchange = Exchange(base: transport, deadline: .milliseconds(20))
        // The failure's instant is read off the main actor, so a busy main
        // actor in a full run does not count against the exchange.
        let task = Task.detached { [query] () -> (Int?, ContinuousClock.Instant) in
            do {
                _ = try await exchange.payload(query)
                return (nil, ContinuousClock.now)
            } catch {
                return ((error as? TransportError)?.statusCode, ContinuousClock.now)
            }
        }

        let first = try await held(transport, sent: 1)
        let refused = ContinuousClock.now
        first.refuse(TransportError(statusCode: 503, body: "down"))
        let (status, failed) = await task.value
        #expect(status == 503)
        #expect(failed - refused < .milliseconds(250), "the exchange failed before the shortest backoff it could not afford")
        #expect(transport.requestCount == 1)
    }

    @Test("a mutation refused with a 503 is sent once and fails")
    func a_mutation_refused_with_a_503_is_sent_once() async throws {
        let transport = ScriptedTransport()
        let exchange = Exchange(base: transport, step: .milliseconds(1))
        let task = Task { try await exchange.payload(mutation) }

        try await held(transport, sent: 1).refuse(TransportError(statusCode: 503, body: "down"))
        #expect(await status(of: task) == 503)
        #expect(transport.requestCount == 1)
    }

    @Test("a mutation refused with a 401 is replayed once, and a 503 on the replay fails it, sent twice")
    func a_mutation_challenged_is_replayed_once_and_not_retried() async throws {
        let transport = ScriptedTransport()
        let challenges = Counter()
        let exchange = Exchange(base: transport, step: .milliseconds(1)) { challenges.increment() }
        let task = Task { try await exchange.payload(mutation) }

        try await held(transport, sent: 1).refuse(TransportError(statusCode: 401, body: "expired"))
        let replay = try await held(transport, sent: 2)
        #expect(replay.request.kind == .mutation)
        replay.refuse(TransportError(statusCode: 503, body: "down"))
        #expect(await status(of: task) == 503)
        #expect(transport.requestCount == 2)
        #expect(challenges.value == 1)
    }

    @Test("a stream that delivered a payload and then failed yields the payload, throws the failure, and is not sent again")
    func a_stream_that_delivered_is_not_sent_again() async throws {
        let transport = ScriptedTransport()
        transport.drive(TestHeaderQuery.name)
        let exchange = Exchange(base: transport, step: .milliseconds(1))
        let stream = exchange.send(query)
        let task = Task {
            var received: [Data] = []
            do {
                for try await payload in stream { received.append(payload) }
                return (received, nil as TransportError?)
            } catch let error as TransportError {
                return (received, error)
            }
        }
        await until { transport.driven.count == 1 }
        let driven = try #require(transport.driven.first)
        driven.send(answer)
        driven.fail(TransportError(statusCode: 503, body: "the stream broke"))

        let (received, error) = try await task.value
        #expect(received == [answer])
        #expect(error?.statusCode == 503)
        #expect(transport.requestCount == 1)
    }

    @Test("a 400 and a failure with no response are not retried: each is sent once")
    func a_failure_a_retry_cannot_mend_is_sent_once() async throws {
        let refused = ScriptedTransport()
        refused.hold(TestHeaderQuery.name)
        let task = Task { [query] in try await Exchange(base: refused, step: .milliseconds(1)).payload(query) }
        try await held(refused, sent: 1).refuse(TransportError(statusCode: 400, body: "bad request"))
        #expect(await status(of: task) == 400)
        #expect(refused.requestCount == 1)

        let unscripted = ScriptedTransport()
        let unanswered = Task { [query] in try await Exchange(base: unscripted, step: .milliseconds(1)).payload(query) }
        #expect(await status(of: unanswered) == 0)
        #expect(unscripted.requestCount == 1)
    }

    @Test("whether a retry mends a failure: a 5xx and a lost or timed-out connection do, a 4xx, a 401, a status 0 and another error do not")
    func mends_classifies_failures() {
        #expect(Exchange.mends(TransportError(statusCode: 500, body: "")))
        #expect(Exchange.mends(TransportError(statusCode: 599, body: "")))
        #expect(Exchange.mends(URLError(.timedOut)))
        #expect(Exchange.mends(URLError(.networkConnectionLost)))
        #expect(Exchange.mends(URLError(.notConnectedToInternet)))
        #expect(Exchange.mends(URLError(.cannotConnectToHost)))
        #expect(!Exchange.mends(TransportError(statusCode: 400, body: "")))
        #expect(!Exchange.mends(TransportError(statusCode: 401, body: "")))
        #expect(!Exchange.mends(TransportError(statusCode: 0, body: "")))
        #expect(!Exchange.mends(URLError(.badURL)))
        #expect(!Exchange.mends(CancellationError()))
    }

    @Test("cancelling the consumer of the exchange's stream while the base holds the request ends the base's stream, so held is empty")
    func cancelling_the_consumer_cancels_the_attempt() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let exchange = Exchange(base: transport, step: .milliseconds(1))
        let stream = exchange.send(query)
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        await until { transport.held.count == 1 }
        task.cancel()
        _ = try? await task.value
        await until { transport.held.isEmpty }
        #expect(transport.requestCount == 1)
    }

    @Test("an environment over an exchange reads a query ready after its first answer was a 503, sent twice")
    func an_environment_over_an_exchange_is_ready_after_a_retry() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let environment = Environment(transport: Exchange(base: transport, step: .milliseconds(1)))
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()

        try await held(transport, sent: 1).refuse(TransportError(statusCode: 503, body: "down"))
        try await held(transport, sent: 2).respond(answer)
        await until {
            guard case .ready = handle.phase else { return false }
            return true
        }
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Jerry Smith")
        #expect(transport.requestCount == 2)
        _ = consume retention
    }

    @Test("a held mutation's optimistic layer stays applied while a query beside it is retried after a 503, and commits when answered")
    func a_retry_beside_a_held_mutation_leaves_its_optimistic_layer() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let environment = Environment(transport: Exchange(base: transport, step: .milliseconds(1)), store: store)
        let rick = TestFavorite_character(anchor: Anchor(record: try #require(store.existing("Character:1")), variables: .none, store: store))
        let optimistic = TestSetFavorite.OptimisticResponse(setFavorite: .init(character: .init(id: "1", favorite: true)))
        let favorite = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true), optimistic: optimistic.variable) }
        await until { transport.held.count == 1 }
        #expect(rick.favorite == true)

        let fetch = Task { try await environment.fetch(TestHeaderQuery(id: "5")) }
        await until { transport.requestCount == 2 && transport.held.count == 2 }
        try #require(transport.held.first { $0.request.kind == .query }).refuse(TransportError(statusCode: 503, body: "down"))
        await until { transport.requestCount == 3 && transport.held.count == 2 }
        #expect(rick.favorite == true, "the retry did not disturb the layer")
        #expect(environment.store.optimisticLayers.count == 1)
        try #require(transport.held.first { $0.request.kind == .query }).respond(answer)
        try await fetch.value
        #expect(rick.favorite == true)
        #expect(environment.store.optimisticLayers.count == 1)

        try #require(transport.held.first { $0.request.kind == .mutation }).respond(fixture("set-favorite-1"))
        let data = try await favorite.value
        #expect(data.setFavorite?.character?.favorite == true)
        #expect(environment.store.optimisticLayers.isEmpty)
        #expect(transport.requests(of: .mutation).count == 1)
        #expect(transport.requests(of: .query).count == 2)
    }
}

/// A token read and replaced from any thread.
final class Token: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    init(_ value: String) { current = value }

    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// A server that refuses the first request of each `X-Stub-Key` with a 401
/// and answers every later one with the `character-header-5` fixture,
/// recording each request's `Authorization` header by its key.
final class ChallengeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var received: [String: [String]] = [:]

    static func authorizations(for key: String) -> [String] { lock.withLock { received[key] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "X-Stub-Key") ?? ""
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let count = Self.lock.withLock {
            Self.received[key, default: []].append(authorization)
            return Self.received[key]?.count ?? 0
        }
        let challenged = count == 1
        let body = challenged ? Data(#"{"message":"expired"}"#.utf8) : fixture("character-header-5")
        let response = HTTPURLResponse(url: request.url!, statusCode: challenged ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
