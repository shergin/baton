import Baton
import Foundation
import Observation
import Testing

@MainActor
@Suite("Delivery", .timeLimit(.minutes(1)))
struct DeliveryTests {
    /// Answers every request with the same response.
    final class OneResponse: Transport, @unchecked Sendable {
        let response: Data
        var requests: [Request] = []
        init(_ response: Data) { self.response = response }

        func execute(_ request: Request) async throws -> Data {
            requests.append(request)
            return response
        }
    }

    /// Streams the first part at once and the second when told.
    final class GatedParts: Transport, @unchecked Sendable {
        let first: Data
        let second: Data
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
        var requests: [Request] = []

        init(_ first: Data, _ second: Data) {
            self.first = first
            self.second = second
        }

        func execute(_ request: Request) async throws -> Data {
            requests.append(request)
            return first
        }

        func stream(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            requests.append(request)
            return AsyncThrowingStream { continuation in
                continuation.yield(first)
                self.continuation = continuation
            }
        }

        func release() {
            continuation?.yield(second)
            continuation?.finish()
        }
    }

    /// Delivers subscription events when told.
    final class Events: SubscriptionTransport, @unchecked Sendable {
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
        var requests: [Request] = []
        var ended = false

        func subscribe(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            requests.append(request)
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
                continuation.onTermination = { _ in self.ended = true }
            }
        }

        func send(_ data: Data) { continuation?.yield(data) }
    }

    func counter(_ body: @escaping @MainActor () -> Void) -> (fired: () -> Int, track: () -> Void) {
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        func track() {
            withObservationTracking { body() } onChange: { counter.fired += 1 }
        }
        return ({ counter.fired }, track)
    }

    func profile(_ environment: Environment) throws -> TestProfileQuery.Data.Character {
        let data = TestProfileQuery.Data(anchor: Anchor(record: environment.store.root, variables: TestProfileQuery(id: "1").variables, store: environment.store))
        return try #require(data.character)
    }

    @Test("field errors land beside the field: a plain read sees null, @catch sees the error, @catch(to: NULL) sees nil, and a cached read agrees")
    func fieldErrors() async throws {
        let environment = Environment(transport: OneResponse(fixture("character-errors")))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character?.testProfile)
        #expect(character.name == "Rick Sanchez")
        guard case .failure(let image) = character.image else {
            Issue.record("expected the image error")
            return
        }
        #expect(image.errors == [FieldError(message: "image service unavailable", path: "character.image")])
        guard case .failure(let location) = character.location else {
            Issue.record("expected the error inside location")
            return
        }
        #expect(location.errors.map(\.path) == ["character.location.name"])
        #expect(character.gender == nil, "@catch(to: NULL) reads the errored field as null")

        // The error is data: a second lens over the store reads the same.
        let again = try #require(try profile(environment).testProfile)
        guard case .failure = again.image else {
            Issue.record("the cached read lost the error")
            return
        }
        let record = try #require(environment.store.existing("Character:1"))
        #expect(record.error(Registry.slot(Registry.type("Character"), "image"))?.message == "image service unavailable")
        #expect(record.error(Registry.slot(Registry.type("Character"), "name")) == nil)
    }

    @Test("a payload that answers an errored field clears the error and notifies the field")
    func errorsClear() async throws {
        let environment = Environment(transport: OneResponse(fixture("character-errors")))
        environment.store.reportMissing = nil
        _ = try await environment.fetch(TestProfileQuery.self, variables: TestProfileQuery(id: "1").variables)
        let character = try #require(try profile(environment).testProfile)
        let (fired, track) = counter { _ = character.image }
        track()
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        #expect(fired() == 1)
        guard case .success(let image) = character.image else {
            Issue.record("the error should be gone")
            return
        }
        #expect(image == "rick.png")
    }

    @Test("a payload that answers an errored field with the same value and no error clears the error; the same error again notifies nothing")
    func errorsClearWithoutAValueChange() async throws {
        let environment = Environment(transport: OneResponse(fixture("character-errors")))
        environment.store.reportMissing = nil
        _ = try await environment.fetch(TestProfileQuery.self, variables: TestProfileQuery(id: "1").variables)
        let character = try #require(try profile(environment).testProfile)
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables)
        let (fired, track) = counter { _ = character.image }

        track()
        environment.store.commit(try Ingest.normalize(fixture("character-errors"), plan: plan))
        #expect(fired() == 0, "the same error on the same null changes nothing")

        environment.store.commit(try Ingest.normalize(fixture("character-errors-answered"), plan: plan))
        #expect(fired() == 1, "the error is gone though the value is still null")
        guard case .success(nil) = character.image else {
            Issue.record("expected a null image without an error, got \(character.image)")
            return
        }

        track()
        environment.store.commit(try Ingest.normalize(fixture("character-errors"), plan: plan))
        #expect(fired() == 2, "the error comes back")
    }

    @Test("an error whose path names a negative list index does not trap and lands on no row")
    func negativeErrorIndex() throws {
        let changes = try Ingest.normalize(fixture("negative-error-index"), plan: TestList.plan.resolve(TestList(page: 1).variables))
        #expect(!changes.fieldErrors.contains { changes.recordTypes[Int($0.record)] == Registry.type("Character") })
    }

    @Test("@required: NONE drops the enclosing lens, LOG reports the path, THROW throws at the read")
    func required() async throws {
        let store = Store()
        store.reportMissing = nil
        let roster = TestRosterQuery(page: 1)
        store.commit(try Ingest.normalize(fixtureData, plan: TestRosterQuery.plan.resolve(roster.variables)))
        let data = TestRosterQuery.Data(anchor: Anchor(record: store.root, variables: roster.variables, store: store))
        #expect(data.characters?.results?.count == 20)
        let edited = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\",\"status\":\"Alive\"", with: "\"name\":\"Morty Smith\",\"status\":null")
        store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestRosterQuery.plan.resolve(roster.variables)))
        let results = try #require(data.characters?.results)
        #expect(results.count == 19, "the row whose required status is null is dropped")
        #expect(!results.contains { $0.name == "Morty Smith" })

        // LOG: the fragment reads as null and the environment is told.
        let environment = Environment(transport: SilentTransport(), store: store)
        var logged: [String] = []
        environment.requiredFieldMissing = { _, path in logged.append(path) }
        let unstated = String(decoding: fixture("character-errors"), as: UTF8.self)
            .replacingOccurrences(of: "\"status\":\"Alive\"", with: "\"status\":null")
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables)
        store.commit(try Ingest.normalize(Data(unstated.utf8), plan: plan))
        #expect(try profile(environment).testProfile == nil)
        #expect(logged == ["status"])

        // THROW: the field's own accessor throws; the semantic field reads non-optional.
        let strict = TestStrict_character(anchor: Anchor(record: try #require(store.existing("Character:1")), variables: .none, store: store))
        let species: String = strict.species
        #expect(species == "Human")
        #expect(throws: RequiredFieldError.self) { try strict.type }
        store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        #expect(try strict.type == "Genius")
    }

    @Test("@throwOnFieldError: the spread throws on an uncaught error, the operation fails, and a caught error does not count")
    func throwOnFieldError() async throws {
        let store = Store()
        store.reportMissing = nil
        let environment = Environment(transport: SilentTransport(), store: store)
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables)
        store.commit(try Ingest.normalize(fixture("character-errors"), plan: plan))
        let character = try profile(environment)
        // `type` is null and @required(action: THROW): the strict fragment throws at the spread.
        #expect(throws: FieldErrors.self) { try character.strict }
        store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        let strict = try character.strict
        #expect(strict.species == "Human")

        // An operation with @throwOnFieldError fails on an uncaught error inside its selection.
        let failing = Environment(transport: OneResponse(fixture("character-name-hidden")))
        failing.store.reportMissing = nil
        let handle = failing.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await handle.settle()
        guard case .failed(let error) = handle.phase, let errors = error as? FieldErrors else {
            Issue.record("expected .failed(FieldErrors), got \(handle.phase)")
            return
        }
        #expect(errors.errors.map(\.path) == ["character.name"])
        #expect(failing.store.existing("Character:1") != nil, "the data is in the store regardless")

        // The same error under @catch does not fail an operation without the directive.
        let caught = Environment(transport: OneResponse(fixture("character-errors")))
        caught.store.reportMissing = nil
        let plain = caught.handle(for: TestProfileQuery(id: "1"))
        plain.retain()
        await plain.settle()
        guard case .ready = plain.phase else {
            Issue.record("expected .ready, got \(plain.phase)")
            return
        }
    }

    @Test("a response with errors and no data fails the fetch with the messages")
    func requestErrors() async throws {
        let environment = Environment(transport: OneResponse(fixture("not-authorized")))
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        handle.retain()
        await handle.settle()
        guard case .failed(let error) = handle.phase, let errors = error as? GraphQLErrors else {
            Issue.record("expected .failed(GraphQLErrors), got \(handle.phase)")
            return
        }
        #expect(errors.messages == ["not authorized"])
    }

    @Test("onError is sent when the environment asks for it")
    func errorBehavior() async throws {
        let transport = OneResponse(fixture("character-deferred-1"))
        let environment = Environment(transport: transport)
        environment.errorBehavior = .null
        _ = try await environment.fetch(TestStrictQuery.self, variables: TestStrictQuery(id: "1").variables)
        let body = String(decoding: try #require(transport.requests.first?.body), as: UTF8.self)
        #expect(body.contains("\"onError\":\"NULL\""))
        #expect(transport.requests.first?.incremental == false)
    }

    @Test("an incremental part is read in the June 2023 and the 2024 formats")
    func incrementalParts() throws {
        let labelled = try Ingest.incremental(fixture("character-deferred-2"))
        #expect(labelled.items.count == 1)
        #expect(labelled.items.first?.path == [.name("character")])
        #expect(labelled.items.first?.label == "TestProfileQuery$defer$TestAppearances_character")
        #expect(!labelled.hasNext)
        let announced = try Ingest.incremental(fixture("character-deferred-1-pending"))
        #expect(announced.pending.map(\.id) == ["0"])
        #expect(announced.pending.first?.path == [.name("character")])
        #expect(announced.hasNext)
        let identified = try Ingest.incremental(fixture("character-deferred-2-pending"))
        #expect(identified.items.first?.id == "0")
        #expect(identified.items.first?.path == nil)
    }

    @Test("a deferred fragment is absent after the first part and present after the second, in both incremental formats")
    func deferred() async throws {
        for (first, second) in [("character-deferred-1", "character-deferred-2"), ("character-deferred-1-pending", "character-deferred-2-pending")] {
            // Straight through `fetch`, so an error in the incremental path surfaces.
            let direct = GatedParts(fixture(first), fixture(second))
            let plain = Environment(transport: direct)
            plain.store.reportMissing = nil
            let fetching = Task { try await plain.fetch(TestProfileQuery.self, variables: TestProfileQuery(id: "1").variables) }
            await until { direct.continuation != nil }
            direct.release()
            let uncaught = try await fetching.value
            #expect(uncaught.isEmpty)
            #expect(plain.store.existing("Episode:2") != nil, "the deferred part landed")

            let transport = GatedParts(fixture(first), fixture(second))
            let environment = Environment(transport: transport)
            environment.store.reportMissing = nil
            let handle = environment.handle(for: TestProfileQuery(id: "1"))
            handle.retain()
            await until { if case .loading = handle.phase { false } else { true } }
            guard case .ready(let data) = handle.phase else {
                Issue.record("expected .ready after the first part, got \(handle.phase)")
                return
            }
            #expect(transport.requests.first?.incremental == true)
            let character = try #require(data.character)
            #expect(character.testProfile?.name == "Rick Sanchez")
            #expect(character.testAppearances == nil, "the deferred fragment has not arrived")
            #expect(handle.isComplete, "the check does not wait for deferred fields")

            let (fired, track) = counter { _ = character.testAppearances }
            track()
            transport.release()
            await handle.settle()
            #expect(fired() == 1, "the body that read the deferred spread re-runs")
            let appearances = try #require(character.testAppearances)
            #expect(appearances.episode.map(\.name) == ["Pilot", "Lawnmower Dog"])
            #expect(environment.store.existing("Episode:2") != nil)
        }
    }

    @Test("a subscription's events commit at the subscription root and append through @appendEdge")
    func subscription() async throws {
        let events = Events()
        let environment = Environment(transport: ListTests.PagingTransport(), subscriptions: events)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character?.testNotes)
        #expect(character.notes.nodes.count == 2)

        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: [character.notes.connectionID]))
        live.retain()
        #expect(live.isActive)
        await until { events.continuation != nil }
        #expect(events.requests.first?.operationName == "TestNoteAdded")

        events.send(fixture("note-added-1"))
        await until { live.events >= 1 }
        #expect(character.notes.nodes.map(\.text).last == "Live from the garage")
        #expect(live.latest?.noteAdded?.noteEdge?.node?.text == "Live from the garage")

        events.send(fixture("note-added-2"))
        await until { live.events >= 2 }
        #expect(character.notes.nodes.count == 4)
        #expect(environment.rootCount == 2, "the subscription is a root while retained")

        live.release()
        #expect(!live.isActive)
        await until { events.ended }
        #expect(environment.rootCount == 1)
    }

    @Test("a subscription value reaches its handle while the handle is retained, and not after")
    func subscriptionResolution() {
        let environment = Environment(transport: SilentTransport(), subscriptions: Events())
        let value = TestNoteAdded(characterId: "1", connections: [])
        #expect(value.subscription == nil)

        let live = environment.subscriptionHandle(for: value)
        live.retain()
        live.retain()
        #expect(value.subscription === live)
        live.release()
        #expect(value.subscription === live, "one owner is left")
        live.release()
        #expect(value.subscription == nil)
    }

    @Test("equal subscriptions on one socket are separate: the end of one leaves the other open")
    func equalSubscriptionsOnOneSocket() async throws {
        /// What each reader saw, by reader.
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var payloads: [String: [String]] = [:]
            private var ended: [String] = []

            func add(_ payload: Data, to reader: String) { lock.withLock { payloads[reader, default: []].append(String(decoding: payload, as: UTF8.self)) } }
            func end(_ reader: String) { lock.withLock { ended.append(reader) } }
            func payloads(of reader: String) -> [String] { lock.withLock { payloads[reader] ?? [] } }
            var finished: [String] { lock.withLock { ended } }
        }
        let server = try SocketServer()
        let socket = GraphQLTransportWebSocket(url: try await server.start())
        defer { server.stop() }
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, text: TestNoteAdded.text, persistedID: TestNoteAdded.persistedID, variables: value.variables)
        let log = Log()
        let readers = Dictionary(uniqueKeysWithValues: ["first", "second"].map { reader in
            (reader, Task {
                for try await payload in socket.subscribe(request) { log.add(payload, to: reader) }
                log.end(reader)
            })
        })

        await until { server.count(of: "subscribe") == 2 }
        #expect(server.offeredProtocols == ["graphql-transport-ws"])
        let ids = server.ids(of: "subscribe")
        #expect(Set(ids).count == 2, "each stream subscribes under its own id")

        // The server completes one. The client has nothing to say about the
        // other: a ping answered after the completion shows it sent no
        // `complete` of its own.
        server.send(#"{"id":"\#(ids[0])","type":"complete"}"#)
        await until { log.finished.count == 1 }
        server.send(#"{"type":"ping"}"#)
        await until { server.count(of: "pong") == 1 }
        #expect(server.count(of: "complete") == 0)

        // The other still receives.
        let survivor = try #require(readers.keys.first { !log.finished.contains($0) })
        server.send(#"{"id":"\#(ids[1])","type":"next","payload":{"data":{"noteAdded":null}}}"#)
        await until { log.payloads(of: survivor) == [#"{"data":{"noteAdded":null}}"#] }

        // Its reader goes away: the client completes that subscription, by its id.
        readers[survivor]?.cancel()
        await until { server.count(of: "complete") == 1 }
        #expect(server.ids(of: "complete") == [ids[1]])
    }

    @Test("the multipart parser yields each part's body however the bytes are chunked")
    func multipart() {
        let body = "\r\n---\r\nContent-Type: application/json\r\n\r\n{\"data\":{\"a\":1},\"hasNext\":true}\r\n---\r\nContent-Type: application/json\r\n\r\n{\"incremental\":[],\"hasNext\":false}\r\n-----\r\n"
        let bytes = Data(body.utf8)
        for chunk in [1, 7, 64, bytes.count] {
            var parser = MultipartParser(boundary: "-")
            var parts: [Data] = []
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunk, bytes.count)
                parts.append(contentsOf: parser.push(bytes[offset..<end]))
                offset = end
            }
            parts.append(contentsOf: parser.finish())
            #expect(parts.map { String(decoding: $0, as: UTF8.self) } == ["{\"data\":{\"a\":1},\"hasNext\":true}", "{\"incremental\":[],\"hasNext\":false}"], "chunks of \(chunk)")
            #expect(parser.finished)
        }
        #expect(MultipartParser.boundary(in: "multipart/mixed; boundary=\"graphql\"; deferSpec=20220824") == "graphql")
        #expect(MultipartParser.boundary(in: "multipart/mixed") == "-")
        #expect(MultipartParser.boundary(in: "application/json") == nil)
    }
}
