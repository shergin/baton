@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

@MainActor
@Suite("Transport", .timeLimit(.minutes(1)))
struct TransportTests {
    /// The JSON object a body holds.
    func object(_ body: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    let textRequest = Request(operationName: "Probe", kind: .query, document: .text("query Probe { a }"), variables: Variables(["id": .string("1")]), errorBehavior: .null)
    let idRequest = Request(operationName: "Probe", kind: .mutation, document: .id("0a1b2c"), variables: .none)

    @Test("the standard encoding writes query for a text document and documentId for an id, never both, with operationName, variables and onError when set")
    func the_standard_encoding_writes_query_for_a_text_and_documentId_for_an_id() throws {
        let text = try object(Encoding.standard.body(textRequest))
        #expect(Set(text.keys) == ["operationName", "query", "variables", "onError"])
        #expect(text["operationName"] as? String == "Probe")
        #expect(text["query"] as? String == "query Probe { a }")
        #expect(text["variables"] as? [String: String] == ["id": "1"])
        #expect(text["onError"] as? String == "NULL")

        let id = try object(Encoding.standard.body(idRequest))
        #expect(Set(id.keys) == ["operationName", "documentId", "variables"])
        #expect(id["documentId"] as? String == "0a1b2c")
        #expect((id["variables"] as? [String: Any])?.isEmpty == true)
    }

    @Test("a request's body is the standard encoding's")
    func a_requests_body_is_the_standard_encodings() {
        for request in [textRequest, idRequest] {
            #expect(request.body == Encoding.standard.body(request))
        }
    }

    @Test("the payload of a transport whose stream finishes empty is a transport error with status 0")
    func the_payload_of_an_empty_stream_is_a_transport_error_with_status_0() async throws {
        struct Empty: Transport {
            func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        do {
            _ = try await Empty().payload(textRequest)
            Issue.record("an empty stream delivered a payload")
        } catch let error as TransportError {
            #expect(error.statusCode == 0)
        }
    }

    /// A transport over `HeaderEcho`, its requests marked with a key of their
    /// own so tests running beside each other count only theirs.
    func echoTransport(key: String, credentials: @escaping @Sendable () async throws -> [String: String]) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderEcho.self]
        return URLSessionTransport(url: URL(string: "https://stub.invalid/graphql")!, headers: ["X-Stub-Key": key], credentials: credentials, session: URLSession(configuration: configuration))
    }

    /// A transport over `EventStreamServer`, its requests marked with a key
    /// of their own so tests running beside each other read only theirs.
    func eventStreamTransport(key: String) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EventStreamServer.self]
        return URLSessionTransport(url: URL(string: "https://stub.invalid/graphql")!, headers: ["X-Stub-Key": key], session: URLSession(configuration: configuration))
    }

    @Test("URLSessionTransport asks a subscription for an event stream and reads it as one payload for each next event, finishing at complete")
    func url_session_transport_reads_a_subscription_as_an_event_stream() async throws {
        let key = UUID().uuidString
        let transport = eventStreamTransport(key: key)
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, kind: .subscription, document: TestNoteAdded.document, variables: value.variables)
        var received: [Data] = []
        for try await payload in transport.send(request) { received.append(payload) }
        #expect(received == EventStreamServer.payloads)
        let accept = try #require(EventStreamServer.accept(for: key))
        #expect(accept.contains("text/event-stream"))
    }

    @Test("an environment whose subscriptions are URLSessionTransport reads each next event of the stream, and ends at complete without opening it again")
    func an_environment_subscribes_over_http() async throws {
        let key = UUID().uuidString
        let environment = Environment(transport: RecordedTransport(), subscriptions: eventStreamTransport(key: key))
        environment.store.reportMissing = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
        let retention = live.retain()
        await until { live.events >= 2 }
        await until { !live.isActive }
        #expect(live.events == 2)
        #expect(live.latest?.noteAdded?.noteEdge?.node?.text == "Second live note")
        guard case .ended(nil) = live.stream else {
            Issue.record("expected the stream ended with no failure, got \(live.stream)")
            return
        }
        #expect(live.resumptions == 0)
        #expect(live.error == nil)
        #expect(EventStreamServer.requests(for: key) == 1)
        _ = consume retention
    }

    @Test("URLSessionTransport reads its credentials for every attempt, so a rotated token reaches the next request")
    func url_session_transport_reads_its_credentials_per_attempt() async throws {
        let key = UUID().uuidString
        let reads = Counter()
        let transport = echoTransport(key: key) {
            ["Authorization": "Bearer \(reads.increment())"]
        }
        let first = try object(try await transport.payload(textRequest))
        let second = try object(try await transport.payload(textRequest))
        #expect(first["authorization"] as? String == "Bearer 1")
        #expect(second["authorization"] as? String == "Bearer 2")
        #expect(HeaderEcho.requests(for: key) == 2)
    }

    @Test("a recorded transport records each request's kind and document")
    func a_recorded_transport_records_each_requests_kind_and_document() async throws {
        let transport = RecordedTransport([
            TestProfileQuery.name: fixture("character-errors"),
            TestCommitVariable.name: fixture("set-favorite-1"),
        ])
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        _ = try await environment.fetch(TestProfileQuery(id: "1"))
        _ = try await environment.mutate(TestCommitVariable(commit: "1"))
        _ = try? await transport.payload(idRequest)
        let requests = transport.requests
        #expect(requests.map(\.kind) == [.query, .mutation, .mutation])
        #expect(requests.map(\.document) == [TestProfileQuery.document, TestCommitVariable.document, .id("0a1b2c")])
        #expect(TestProfileQuery.document == .text(TestProfileQuery.text ?? ""), "the test target sets no persistConfig")
    }

    @Test("the environment's subscriptions take any transport, and a recorded one serves a subscription its one event")
    func the_environments_subscriptions_take_any_transport() async throws {
        let events = RecordedTransport([TestNoteAdded.name: fixture("note-added-1")])
        let environment = Environment(transport: SilentTransport(), subscriptions: events)
        environment.store.reportMissing = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
        let retention = live.retain()
        await until { live.events >= 1 }
        #expect(live.latest?.noteAdded?.noteEdge?.node?.text == "Live from the garage")
        #expect(events.requests.map(\.kind) == [.subscription])
        #expect(events.requests.first?.document == TestNoteAdded.document)
        _ = consume retention
    }

    @Test("a socket's subscribe payload is the encoding's JSON: the standard one's query and operationName, or what another encoding writes")
    func a_sockets_subscribe_payload_is_the_encodings_json() async throws {
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, kind: TestNoteAdded.kind, document: TestNoteAdded.document, variables: value.variables)
        do {
            let server = try SocketServer()
            defer { server.stop() }
            let socket = GraphQLTransportWebSocket(url: try await server.start())
            let reader = Task { for try await _ in socket.send(request) {} }
            await until { server.subscriptionPayloads.count == 1 }
            let payload = try object(try #require(server.subscriptionPayloads.first))
            #expect(payload["operationName"] as? String == "TestNoteAdded")
            #expect(payload["query"] as? String == TestNoteAdded.text)
            #expect(payload["documentId"] == nil)
            #expect((payload["variables"] as? [String: Any])?["characterId"] as? String == "1")
            reader.cancel()
            await until { server.closed == 1 }
        }
        do {
            let server = try SocketServer()
            defer { server.stop() }
            let byID = Encoding { request in
                guard case .id(let id) = request.document else { return Data("{}".utf8) }
                return Data(#"{"id":"\#(id)"}"#.utf8)
            }
            let socket = GraphQLTransportWebSocket(url: try await server.start(), encoding: byID)
            let persisted = Request(operationName: TestNoteAdded.name, kind: .subscription, document: .id("0a1b2c"), variables: value.variables)
            let reader = Task { for try await _ in socket.send(persisted) {} }
            await until { server.subscriptionPayloads.count == 1 }
            let payload = try object(try #require(server.subscriptionPayloads.first))
            #expect(payload as? [String: String] == ["id": "0a1b2c"])
            reader.cancel()
            await until { server.closed == 1 }
        }
    }

    @Test("a query over the socket answers with the one payload the server completes after")
    func a_query_over_the_socket_answers_with_one_payload() async throws {
        let server = try SocketServer()
        defer { server.stop() }
        let socket = GraphQLTransportWebSocket(url: try await server.start())
        let answer = Task { try await socket.payload(textRequest) }
        await until { server.count(of: "subscribe") == 1 }
        let id = try #require(server.ids(of: "subscribe").first)
        server.send(#"{"id":"\#(id)","type":"next","payload":{"data":{"a":1}}}"#)
        server.send(#"{"id":"\#(id)","type":"complete"}"#)
        let payload = try await answer.value
        #expect(String(decoding: payload, as: UTF8.self) == #"{"data":{"a":1}}"#)
    }
}

/// A count read and raised from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// A server that answers every request with `{"authorization": ...}`, the
/// request's `Authorization` header, and counts the requests by their
/// `X-Stub-Key` header.
final class HeaderEcho: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func requests(for key: String) -> Int { lock.withLock { counts[key] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let key = request.value(forHTTPHeaderField: "X-Stub-Key") {
            Self.lock.withLock { Self.counts[key, default: 0] += 1 }
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let body = try? JSONSerialization.data(withJSONObject: ["authorization": authorization])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A `graphql-sse` server in its distinct-connections mode: it answers every
/// request with an event stream of two `next` events and `complete`, three
/// bytes at a time, and records each request's `Accept` header by its
/// `X-Stub-Key` header.
final class EventStreamServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var accepts: [String: [String]] = [:]

    /// The payloads the stream carries, recorded subscription events.
    static let payloads = ["note-added-1", "note-added-2"].map {
        Data(String(decoding: fixture($0), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    static func requests(for key: String) -> Int { lock.withLock { accepts[key]?.count ?? 0 } }
    static func accept(for key: String) -> String? { lock.withLock { accepts[key]?.first } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let key = request.value(forHTTPHeaderField: "X-Stub-Key") {
            let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
            Self.lock.withLock { Self.accepts[key, default: []].append(accept) }
        }
        var body = Data()
        for payload in Self.payloads {
            body.append(Data("event: next\ndata: ".utf8))
            body.append(payload)
            body.append(Data("\n\n".utf8))
        }
        body.append(Data("event: complete\ndata:\n\n".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = min(offset + 3, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
