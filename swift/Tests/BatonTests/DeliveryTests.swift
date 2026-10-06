@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import Testing

@MainActor
@Suite("Delivery", .timeLimit(.minutes(1)))
struct DeliveryTests {
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

        /// An operation that answers once gets the first part alone; a
        /// deferred one the first part now and the second on `release`.
        func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            requests.append(request)
            return AsyncThrowingStream { continuation in
                continuation.yield(first)
                guard request.incremental else {
                    continuation.finish()
                    return
                }
                self.continuation = continuation
            }
        }

        func release() {
            continuation?.yield(second)
            continuation?.finish()
        }

        func fail() {
            continuation?.finish(throwing: TransportError(statusCode: 502, body: "the stream broke"))
        }
    }

    /// Streams the parts it was given and never finishes, as a server that
    /// leaves the connection open after its last part.
    final class OpenParts: Transport, @unchecked Sendable {
        let parts: [Data]
        init(_ parts: [Data]) { self.parts = parts }

        func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { continuation in
                for part in parts { continuation.yield(part) }
            }
        }
    }

    /// Delivers subscription events when told.
    final class Events: Transport, @unchecked Sendable {
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
        var requests: [Request] = []
        var ended = false

        func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
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

    /// A response like `character-errors` whose image error carries
    /// `extensions` of every JSON kind and whose location error carries none.
    /// No fixture under `spec/` has `extensions`.
    static let extensionsResponse = #"{"data":{"character":{"id":"1","name":"Rick Sanchez","origin":{"id":"1","name":"Earth (C-137)"},"status":"Alive","image":null,"location":{"id":"20","name":null,"dimension":"Replacement Dimension"},"gender":null,"species":"Human","type":null}},"errors":[{"message":"image service unavailable","extensions":{"code":"FORBIDDEN","retryAfter":30,"ratio":0.5,"flags":[true,null],"nested":{"a":"b"}},"path":["character","image"]},{"message":"location name redacted","path":["character","location","name"]}]}"#

    /// The `extensions` of `extensionsResponse`'s image error, as a variable.
    static let extensions: Variable = .object([
        "code": .string("FORBIDDEN"),
        "retryAfter": .int(30),
        "ratio": .double(0.5),
        "flags": .list([.bool(true), .null]),
        "nested": .object(["a": .string("b")]),
    ])

    /// The case of a subscription's stream, with the failure that ended it.
    func state(_ stream: Baton.Stream) -> String {
        switch stream {
        case .idle: "idle"
        case .connecting: "connecting"
        case .open: "open"
        case .waiting: "waiting"
        case .ended(nil): "ended"
        case .ended(.some(let failure)): "ended(\(failure))"
        }
    }

    func profile(_ environment: Environment) throws -> TestProfileQuery.Data.Character {
        let data = TestProfileQuery.Data(anchor: Anchor(record: environment.store.root, variables: TestProfileQuery(id: "1").variables, store: environment.store))
        return try #require(data.character)
    }

    @Test("field errors land beside the field: a plain read sees null, @catch sees the error, @catch(to: NULL) sees nil, and a cached read agrees")
    func fieldErrors() async throws {
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("character-errors")]))
        environment.log = nil
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        let retention = handle.retain()
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
        withExtendedLifetime(retention) {}
    }

    @Test("a payload that answers an errored field clears the error and notifies the field")
    func errorsClear() async throws {
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("character-errors")]))
        environment.log = nil
        try await environment.fetch(TestProfileQuery(id: "1"))
        let character = try #require(try profile(environment).testProfile)
        let (fired, track) = counter { _ = character.image }
        track()
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: environment.store.keys)
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
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("character-errors")]))
        environment.log = nil
        try await environment.fetch(TestProfileQuery(id: "1"))
        let character = try #require(try profile(environment).testProfile)
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: environment.store.keys)
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

    @Test("an error under a parent the server nulled lands on that parent with its whole path, and one with no path still counts")
    func errorsUnderANullParent() throws {
        let store = Store()
        let changes = try Ingest.normalize(fixture("character-origin-null"), plan: TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: store.keys))
        store.log = nil
        store.commit(changes)
        let character = try #require(store.existing("Character:1"))
        let type = Registry.type("Character")
        #expect(character.error(Registry.slot(type, "origin")) == FieldError(message: "origin name unavailable", path: "character.origin.name"))
        #expect(character.error(Registry.slot(type, "name")) == nil, "not on the sibling of the null link")
        #expect(changes.fieldErrors.count == 1)
        #expect(changes.unplacedErrors == [FieldError(message: "the service is degraded", path: "")])
        #expect(changes.uncaughtFieldErrors.contains(FieldError(message: "the service is degraded", path: "")))
    }

    @Test("an error whose path goes through a null element, past a list's end or below a scalar lands on the last field the path reached")
    func errorsWherePathsStop() throws {
        let changes = try Ingest.normalize(fixture("characters-with-gaps-errors"), plan: TestList.plan.resolve(TestList(page: 1).variables, in: Keys()))
        let placed = changes.fieldErrors.map { (changes.recordKeys[Int($0.record)], Registry.storageKey($0.slot), $0.error.message) }
        #expect(placed.count == 3)
        #expect(placed.contains { $0 == ("client:root:characters(page:1)", "results", "row hidden") }, "\(placed)")
        #expect(placed.contains { $0 == ("client:root:characters(page:1)", "results", "past the end") }, "\(placed)")
        #expect(placed.contains { $0 == ("Character:7", "name", "below a scalar") }, "\(placed)")
    }

    @Test("an error whose path names a negative list index does not trap and lands on no row")
    func negativeErrorIndex() throws {
        let changes = try Ingest.normalize(fixture("negative-error-index"), plan: TestList.plan.resolve(TestList(page: 1).variables, in: Keys()))
        #expect(!changes.fieldErrors.contains { changes.recordTypes[Int($0.record)] == Registry.type("Character") })
    }

    @Test("an error whose path holds an index that is not an integer names nothing, and the data commits")
    func floatErrorIndex() throws {
        let changes = try Ingest.normalize(fixture("float-error-index"), plan: TestList.plan.resolve(TestList(page: 1).variables, in: Keys()))
        #expect(changes.recordKeys.contains("Character:1"))
        #expect(changes.fieldErrors.isEmpty)
        #expect(changes.unplacedErrors.map(\.message) == ["a float index"])
    }

    @Test("@required: NONE drops the enclosing lens, LOG reports the path, THROW throws at the read")
    func required() async throws {
        let store = Store()
        store.log = nil
        let roster = TestRosterQuery(page: 1)
        store.commit(try Ingest.normalize(fixtureData, plan: TestRosterQuery.plan.resolve(roster.variables, in: store.keys)))
        let data = TestRosterQuery.Data(anchor: Anchor(record: store.root, variables: roster.variables, store: store))
        #expect(data.characters?.results?.count == 20)
        let edited = String(decoding: fixtureData, as: UTF8.self)
            .replacingOccurrences(of: "\"name\":\"Morty Smith\",\"status\":\"Alive\"", with: "\"name\":\"Morty Smith\",\"status\":null")
        store.commit(try Ingest.normalize(Data(edited.utf8), plan: TestRosterQuery.plan.resolve(roster.variables, in: store.keys)))
        let results = try #require(data.characters?.results)
        #expect(results.count == 19, "the row whose required status is null is dropped")
        #expect(!results.contains { $0.name == "Morty Smith" })

        // LOG: the fragment reads as null and the environment is told.
        let environment = Environment(transport: SilentTransport(), store: store)
        final class Logged: @unchecked Sendable { var paths: [String] = [] }
        let logged = Logged()
        environment.log = { event in if case .requiredFieldMissing(_, let path) = event { logged.paths.append(path) } }
        let unstated = String(decoding: fixture("character-errors"), as: UTF8.self)
            .replacingOccurrences(of: "\"status\":\"Alive\"", with: "\"status\":null")
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: store.keys)
        store.commit(try Ingest.normalize(Data(unstated.utf8), plan: plan))
        // Read through a handle, whose lenses know the environment to report
        // to; a lens made by hand has none.
        let handle = environment.handle(for: TestProfileQuery(id: "1"), fetchPolicy: .storeOnly)
        guard case .ready(let profile) = handle.phase else {
            Issue.record("expected the profile from the store, got \(handle.phase)")
            return
        }
        #expect(try #require(profile.character).testProfile == nil)
        #expect(logged.paths == ["status"])

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
        store.log = nil
        let environment = Environment(transport: SilentTransport(), store: store)
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: store.keys)
        store.commit(try Ingest.normalize(fixture("character-errors"), plan: plan))
        let character = try profile(environment)
        // `type` is null and @required(action: THROW): the strict fragment throws at the spread.
        #expect(throws: FieldErrors.self) { try character.strict }
        store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        let strict = try character.strict
        #expect(strict.species == "Human")

        // An operation with @throwOnFieldError fails on an uncaught error inside its selection.
        let failing = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-name-hidden")]))
        failing.log = nil
        let handle = failing.handle(for: TestStrictQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .failed(let error) = handle.phase, let errors = error as? FieldErrors else {
            Issue.record("expected .failed(FieldErrors), got \(handle.phase)")
            return
        }
        #expect(errors.errors.map(\.path) == ["character.name"])
        #expect(failing.store.existing("Character:1") != nil, "the data is in the store regardless")

        // The same error under @catch does not fail an operation without the directive.
        let caught = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("character-errors")]))
        caught.log = nil
        let plain = caught.handle(for: TestProfileQuery(id: "1"))
        let plainRetention = plain.retain()
        await plain.settle()
        guard case .ready = plain.phase else {
            Issue.record("expected .ready, got \(plain.phase)")
            return
        }
        withExtendedLifetime((retention, plainRetention)) {}
    }

    @Test("a @throwOnFieldError operation fails when a later commit puts an error in its selection, and recovers when one clears it")
    func throwingPhaseFollowsCommits() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-deferred-1")]))
        environment.log = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready = handle.phase else { Issue.record("expected ready, got \(handle.phase)"); return }

        // Another operation's response names the same character's name as errored.
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: environment.store.keys)
        let hidden = String(decoding: fixture("character-deferred-1"), as: UTF8.self)
            .replacingOccurrences(of: #""name":"Rick Sanchez""#, with: #""name":null"#)
            .replacingOccurrences(of: #","hasNext":true}"#, with: #","errors":[{"message":"name hidden","path":["character","name"]}]}"#)
        environment.store.commit(try Ingest.normalize(Data(hidden.utf8), plan: plan))
        guard case .failed(let error) = handle.phase, error is FieldErrors else { Issue.record("expected the field error, got \(handle.phase)"); return }

        environment.store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        guard case .ready = handle.phase else { Issue.record("expected ready again, got \(handle.phase)"); return }
        withExtendedLifetime(retention) {}
    }

    @Test("Environment.fetch of an operation that throws throws the field errors its handle fails on, and not an error inside a spread")
    func fetchThrowsAsTheHandleFails() async throws {
        let environment = Environment(transport: RecordedTransport([
            TestThrowingSpread.name: fixture("character-name-hidden"),
            TestStrictQuery.name: fixture("character-name-hidden"),
        ]))
        environment.log = nil
        try await environment.fetch(TestThrowingSpread(id: "1"))
        let handle = environment.handle(for: TestThrowingSpread(id: "1"), fetchPolicy: .storeOnly)
        guard case .ready = handle.phase else {
            Issue.record("the error is the spread's to weigh, got \(handle.phase)")
            return
        }
        let own = await #expect(throws: FieldErrors.self) { try await environment.fetch(TestStrictQuery(id: "1")) }
        #expect(own?.errors.map(\.path) == ["character.name"])

        let unplaced = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-unplaced-error")]))
        unplaced.log = nil
        let carried = await #expect(throws: FieldErrors.self) { try await unplaced.fetch(TestStrictQuery(id: "1")) }
        #expect(carried?.errors.map(\.message) == ["rate limited"])
    }

    @Test("a response with errors and no data fails the fetch with the messages")
    func requestErrors() async throws {
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("not-authorized")]))
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .failed(let error) = handle.phase, let errors = error as? GraphQLErrors else {
            Issue.record("expected .failed(GraphQLErrors), got \(handle.phase)")
            return
        }
        #expect(errors.messages == ["not authorized"])
        withExtendedLifetime(retention) {}
    }

    @Test("a field error's extensions read back through @catch as the JSON value the server sent, and an error without them reads nil")
    func fieldErrorExtensions() async throws {
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: Data(Self.extensionsResponse.utf8)]))
        environment.log = nil
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        let character = try #require(try profile(environment).testProfile)
        guard case .failure(let image) = character.image else {
            Issue.record("expected the image error")
            return
        }
        #expect(image.errors.map(\.extensions) == [Self.extensions])
        #expect(image.errors.map(\.message) == ["image service unavailable"])
        guard case .failure(let location) = character.location else {
            Issue.record("expected the error inside location")
            return
        }
        #expect(location.errors.map(\.extensions) == [nil])
        withExtendedLifetime(retention) {}
    }

    @Test("a response with errors and no data fails the fetch with GraphQL errors that keep their extensions beside their messages")
    func requestErrorExtensions() async throws {
        let response = #"{"data":null,"errors":[{"message":"not authorized","extensions":{"code":"FORBIDDEN","retryAfter":30,"ratio":0.5,"flags":[true,null],"nested":{"a":"b"}}},{"message":"try again"}]}"#
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: Data(response.utf8)]))
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .failed(let error) = handle.phase, let errors = error as? GraphQLErrors else {
            Issue.record("expected .failed(GraphQLErrors), got \(handle.phase)")
            return
        }
        #expect(errors.messages == ["not authorized", "try again"])
        #expect(errors.errors.map(\.extensions) == [Self.extensions, nil])
        #expect(errors.errors.map(\.path) == ["", ""])
        withExtendedLifetime(retention) {}
    }

    @Test("the scanner reads any JSON value as a variable: objects, lists, strings, booleans, null, ints, and doubles for fractions, exponents and numbers past Int")
    func variablesFromJSON() throws {
        let json = #"{"code":"FORBIDDEN","retryAfter":30,"ratio":0.5,"flags":[true,null],"nested":{"a":"b"}}"#
        #expect(try Ingest.variable(Data(json.utf8)) == Self.extensions)
        #expect(try Ingest.variable(Data(Self.extensions.json.utf8)) == Self.extensions, "a value's own JSON text reads back as the value")
        #expect(try Ingest.variable(Data("1e3".utf8)) == .double(1000))
        #expect(try Ingest.variable(Data("-7".utf8)) == .int(-7))
        guard case .double = try Ingest.variable(Data("99999999999999999999".utf8)) else {
            Issue.record("a number past Int reads as a double")
            return
        }
    }

    @Test("onError is sent as the operation names it, and not at all when baton.json names none")
    func errorBehavior() async throws {
        let response = fixture("character-deferred-1")
        let transport = RecordedTransport([TestStrictQuery.name: response, TestNullsOnError.name: response])
        let environment = Environment(transport: transport)
        try await environment.fetch(TestStrictQuery(id: "1"))
        try await environment.fetch(TestNullsOnError(id: "1"))
        let bodies = transport.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(!bodies[0].contains("onError"))
        #expect(bodies[1].contains("\"onError\":\"NULL\""))
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

    @Test("a deferred response is fetched when its stream completes: one that fails after the first part keeps its data and stamps no fetch time")
    func fetchTimeAtCompletion() async throws {
        for completes in [true, false] {
            let transport = GatedParts(fixture("character-deferred-1"), fixture("character-deferred-2"))
            let environment = Environment(transport: transport)
            environment.log = nil
            let handle = environment.handle(for: TestProfileQuery(id: "1"))
            let retention = handle.retain()
            await until { if case .loading = handle.phase { false } else { true } }
            #expect(handle.fetchTime == nil, "the first part is not the whole response")
            if completes { transport.release() } else { transport.fail() }
            await handle.settle()
            guard case .ready = handle.phase else {
                Issue.record("the data stays, got \(handle.phase)")
                return
            }
            #expect((handle.fetchTime != nil) == completes)
            _ = consume retention
        }
    }

    @Test("a deferred response fetched by no handle dates its operation when its stream completes, not at its first part")
    func deferredFetchDatesAtCompletion() async throws {
        let transport = GatedParts(fixture("character-deferred-1"), fixture("character-deferred-2"))
        let environment = Environment(transport: transport)
        environment.log = nil
        let fetching = Task { try await environment.fetch(TestProfileQuery(id: "1")) }
        await until { environment.store.existing("Character:1") != nil }
        let probe = environment.handle(for: TestProfileQuery(id: "1"), fetchPolicy: .storeOnly)
        #expect(probe.fetchTime == nil, "the first part is not the whole response")
        transport.release()
        try await fetching.value
        #expect(probe.fetchTime != nil, "the completed stream dated the operation")
    }

    @Test("a deferred fetch whose stream broke after the first part fetches again when a view attaches it under the default policy")
    func brokenStreamFetchesAgain() async throws {
        let transport = GatedParts(fixture("character-deferred-1"), fixture("character-deferred-2"))
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        let retention = handle.retain()
        await until { if case .loading = handle.phase { false } else { true } }
        transport.fail()
        await handle.settle()
        #expect(handle.fetchTime == nil)
        #expect(!handle.isStale, "an operation never fetched whole has no age")
        _ = consume retention

        let again = environment.handle(for: TestProfileQuery(id: "1"))
        #expect(again === handle)
        let againRetention = again.retain()
        await until { transport.requests.count == 2 }
        transport.release()
        await again.settle()
        guard case .ready(let data) = again.phase else {
            Issue.record("expected ready, got \(again.phase)")
            return
        }
        #expect(data.character?.testAppearances?.episode.map(\.name) == ["Pilot", "Lawnmower Dog"])
        #expect(again.fetchTime != nil)
        _ = consume againRetention
    }

    /// Fetches the profile through parts in the 2024 format and returns the
    /// store and the paths of the field errors the log heard left uncaught.
    func fetchProfile(_ parts: [String]) async throws -> (Store, [String]) {
        let environment = Environment(transport: OpenParts(parts.map { fixture($0) }))
        let events = LogTests.Events()
        environment.log = events.log
        final class Done: @unchecked Sendable { var done = false }
        let done = Done()
        Task {
            try await environment.fetch(TestProfileQuery(id: "1"))
            done.done = true
        }
        await until { done.done }
        return (environment.store, events.fieldErrors)
    }

    @Test("a part's subPath places its data below the announced path, and the stream ends at hasNext false though the connection stays open")
    func subPathAndHasNext() async throws {
        let (store, uncaught) = try await fetchProfile(["character-deferred-1-pending", "character-deferred-2-subpath", "character-deferred-3-subpath"])
        #expect(uncaught.isEmpty)
        let episode = try #require(store.existing("Episode:2"))
        #expect(episode.read(Registry.slot(episode.type, "name")) == .string("Lawnmower Dog"))
        #expect(episode.read(Registry.slot(episode.type, "air_date")) == .string("December 9, 2013"), "the third part's subPath")
    }

    @Test("a part's own errors land on the fields they name, by the response's paths")
    func partErrors() async throws {
        let (store, uncaught) = try await fetchProfile(["character-deferred-1-pending", "character-deferred-2-errors"])
        let episode = try #require(store.existing("Episode:1"))
        #expect(episode.error(Registry.slot(episode.type, "name"))?.message == "name hidden")
        #expect(uncaught == ["character.episode.0.name"], "the log hears the part's error once, at its path")
    }

    @Test("an announced part the server could not deliver puts its errors on the fields it would have filled")
    func failedPart() async throws {
        let (store, uncaught) = try await fetchProfile(["character-deferred-1-pending", "character-deferred-2-failed"])
        let character = try #require(store.existing("Character:1"))
        #expect(character.error(Registry.slot(character.type, "episode"))?.message == "appearances unavailable")
        #expect(uncaught == ["character"], "the log hears the part's error once, at the announced path")
    }

    @Test("a deferred fragment is absent after the first part and present after the second, in both incremental formats")
    func deferred() async throws {
        for (first, second) in [("character-deferred-1", "character-deferred-2"), ("character-deferred-1-pending", "character-deferred-2-pending")] {
            // Straight through `fetch`, so an error in the incremental path surfaces.
            let direct = GatedParts(fixture(first), fixture(second))
            let plain = Environment(transport: direct)
            let events = LogTests.Events()
            plain.log = events.log
            let fetching = Task { try await plain.fetch(TestProfileQuery(id: "1")) }
            await until { direct.continuation != nil }
            direct.release()
            try await fetching.value
            #expect(events.fieldErrors.isEmpty, "\(events.fieldErrors)")
            #expect(plain.store.existing("Episode:2") != nil, "the deferred part landed")

            let transport = GatedParts(fixture(first), fixture(second))
            let environment = Environment(transport: transport)
            environment.log = nil
            let handle = environment.handle(for: TestProfileQuery(id: "1"))
            let retention = handle.retain()
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
            withExtendedLifetime(retention) {}
        }
    }

    @Test("an attach under the default policy fetches a deferred fragment memory lacks, and the initial part renders meanwhile")
    func deferredPartMissingFromMemory() async throws {
        let transport = GatedParts(fixture("character-deferred-1"), fixture("character-deferred-2"))
        let environment = Environment(transport: transport)
        environment.log = nil
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables, in: environment.store.keys)
        environment.store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        let handle = environment.handle(for: TestProfileQuery(id: "1"))
        let retention = handle.retain()
        guard case .ready(let data) = handle.phase else {
            Issue.record("the initial part renders from memory, got \(handle.phase)")
            return
        }
        #expect(data.character?.testAppearances == nil)
        #expect(handle.isRefreshing)
        await until { transport.continuation != nil }
        transport.release()
        await handle.settle()
        #expect(transport.requests.count == 1)
        #expect(data.character?.testAppearances?.episode.map(\.name) == ["Pilot", "Lawnmower Dog"])
        _ = consume retention
    }

    @Test("an attach that fetches a deferred fragment memory lacks keeps the field the initial part selects outside the fragment")
    func deferredPartSharingAField() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        // The initial part: `episode { id }` arrived, the fragment's
        // `episode { name air_date }` is on its way.
        let plan = TestOverlapQuery.plan.resolve(TestOverlapQuery(id: "1").variables, in: environment.store.keys)
        environment.store.commit(try Ingest.normalize(fixture("character-overlap-1"), plan: plan))
        let handle = environment.handle(for: TestOverlapQuery(id: "1"))
        let retention = handle.retain()
        guard case .ready(let data) = handle.phase else {
            Issue.record("the initial part renders from memory, got \(handle.phase)")
            return
        }
        #expect(data.character?.episode.map(\.id) == ["1", "2"])
        #expect(handle.isRefreshing, "the fragment is fetched")
        _ = consume retention
    }

    @Test("a subscription's events commit at the subscription root and append through @appendEdge")
    func subscription() async throws {
        let events = Events()
        let environment = Environment(transport: notesTransport(), subscriptions: events)
        environment.log = nil
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character?.testNotes)
        #expect(character.notes.nodes.count == 2)

        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: [character.notes.connectionID]))
        let liveRetention = live.retain()
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
        #expect(environment.store.rootCount == 2, "the subscription is a root while retained")

        _ = consume liveRetention
        #expect(!live.isActive)
        await until { events.ended }
        #expect(environment.store.rootCount == 1)
        withExtendedLifetime(retention) {}
    }

    @Test("a subscription root's field is keyed by its arguments and freed with its subscription")
    func aSubscriptionsKeyIsFreedWithIt() async throws {
        let events = Events()
        let environment = Environment(transport: SilentTransport(), subscriptions: events)
        environment.log = nil
        let store = environment.store
        let subscription = Registry.type("Subscription")
        do {
            let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: []))
            let retention = live.retain()
            await until { events.continuation != nil }
            events.send(fixture("note-added-1"))
            await until { live.events >= 1 }
            #expect(live.latest?.noteAdded?.noteEdge?.node?.text == "Live from the garage")
            store.collect()
            #expect(store.keys.count(on: subscription) == 1, "the held subscription's root field is keyed by its argument")
            #expect(store.subscriptionRoot.renderedKeyCount == 1)
            _ = consume retention
            await until { events.ended }
        }
        // The released subscription's root left at once; once its handle
        // is gone, nothing names the key.
        await until {
            store.collect()
            return store.keys.count(on: subscription) == 0
        }
        #expect(store.keys.count(on: subscription) == 0, "the key went with the subscription")
        #expect(store.subscriptionRoot.renderedKeyCount == 0, "and so did the root's entry under it")
    }

    @Test("an event with errors and no data is one bad event: the subscription shows it and goes on, and the next good event clears it")
    func badEvent() async throws {
        let events = Events()
        let environment = Environment(transport: SilentTransport(), subscriptions: events)
        environment.log = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "events-\(#line)", connections: []))
        let liveRetention = live.retain()
        await until { events.continuation != nil }
        events.send(fixture("not-authorized"))
        await until { live.error != nil }
        #expect((live.error as? GraphQLErrors)?.messages == ["not authorized"])
        #expect(live.isActive)
        events.send(fixture("note-added-1"))
        await until { live.events == 1 }
        #expect(live.error == nil)
        _ = consume liveRetention
    }

    @Test("retry opens a stream the server ended, and the stream it replaces leaves the new one's state alone")
    func retrySubscription() async throws {
        let events = Events()
        let environment = Environment(transport: SilentTransport(), subscriptions: events)
        environment.log = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "events-\(#line)", connections: []))
        let liveRetention = live.retain()
        await until { events.requests.count == 1 }
        events.continuation?.finish()
        await until { !live.isActive }
        live.retry()
        await until { events.requests.count == 2 }
        #expect(live.isActive)

        // A retry while open replaces the stream; the old one ending later
        // does not close the new one.
        live.retry()
        await until { events.requests.count == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(live.isActive)
        events.send(fixture("note-added-1"))
        await until { live.events == 1 }
        _ = consume liveRetention
    }

    @Test("a bad event the replaced stream was reading leaves no error on the stream that replaced it")
    func badEventOfAReplacedStream() async throws {
        let events = Events()
        let environment = Environment(transport: RecordedTransport(), subscriptions: events)
        environment.log = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "events-\(#line)", connections: []))
        let liveRetention = live.retain()
        await until { events.continuation != nil }
        events.send(fixture("not-authorized"))
        // One turn of the main actor hands the event to the ingest, off the
        // main actor; the retry lands before the handle hears back from it.
        await Task.yield()
        live.retry()
        await until { events.requests.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(live.error == nil, "the replaced stream's bad event is not the new stream's")
        #expect(live.isActive)
        _ = consume liveRetention
    }

    @Test("an event in hand when its subscription is released is not committed, while the events before it are")
    func eventInHandAtTheRelease() async throws {
        let events = Events()
        let environment = Environment(transport: notesTransport(), subscriptions: events)
        environment.log = nil
        // The query keeps the connection the events append to, so a payload
        // that landed would stay in the store rather than be collected.
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character?.testNotes)
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "1", connections: [character.notes.connectionID]))
        let liveRetention = live.retain()
        await until { events.continuation != nil }

        events.send(fixture("note-added-1"))
        await until { live.events == 1 }
        #expect(character.notes.nodes.map(\.text).last == "Live from the garage", "the event before the release landed")

        // One turn of the main actor hands the event to the ingest, off the
        // main actor; the release lands before the handle hears back from
        // it, and the commit finds the task cancelled.
        events.send(fixture("note-added-2"))
        await Task.yield()
        _ = consume liveRetention
        // Long past the few milliseconds the event takes to read: had it
        // been committed, it would be in the store by now.
        try await Task.sleep(for: .milliseconds(200))
        #expect(live.events == 1)
        #expect(environment.store.existing("Note:n7") == nil, "the event in hand at the release did not land")
        #expect(character.notes.nodes.count == 3)
        _ = consume retention
    }

    @Test("a stream the transport ends with a cancellation of its own ends the subscription, and a later retain opens it again")
    func streamEndedByTheTransportsCancellation() async throws {
        let events = Events()
        let environment = Environment(transport: RecordedTransport(), subscriptions: events)
        environment.log = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "events-\(#line)", connections: []))
        let liveRetention = live.retain()
        await until { events.requests.count == 1 }
        events.continuation?.finish(throwing: CancellationError())
        await until { !live.isActive }
        #expect(live.error == nil, "a cancellation is no error to show")
        let againRetention = live.retain()
        await until { events.requests.count == 2 }
        #expect(live.isActive)
        _ = consume againRetention
        _ = consume liveRetention
    }

    @Test("a subscription's stream is idle until retained, connecting until its first event, open after it, and idle once released")
    func streamBeforeAndAfterTheFirstEvent() async throws {
        let events = Events()
        let environment = Environment(transport: SilentTransport(), subscriptions: events)
        environment.log = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "events-\(#line)", connections: []))
        #expect(state(live.stream) == "idle")
        #expect(!live.isActive)
        let liveRetention = live.retain()
        #expect(state(live.stream) == "connecting")
        #expect(live.isActive)
        await until { events.continuation != nil }
        #expect(state(live.stream) == "connecting", "a stream the transport opened has sent nothing yet")
        events.send(fixture("note-added-1"))
        await until { live.events == 1 }
        #expect(state(live.stream) == "open")
        #expect(live.isActive)
        _ = consume liveRetention
        #expect(state(live.stream) == "idle")
        #expect(!live.isActive)
    }

    @Test("a stream the server completes reads ended with no failure, a retry reads connecting, and an error frame ends it with the request failure holding the frame's errors, with no reconnection")
    func streamEnds() async throws {
        let server = try SocketServer()
        let socket = GraphQLTransportWebSocket(url: try await server.start())
        defer { server.stop() }
        let environment = Environment(transport: SilentTransport(), subscriptions: socket)
        environment.log = nil
        let live = environment.subscriptionHandle(for: TestNoteAdded(characterId: "events-\(#line)", connections: []))
        let liveRetention = live.retain()
        await until { server.count(of: "subscribe") == 1 }
        let first = try #require(server.ids(of: "subscribe").first)
        server.send(#"{"id":"\#(first)","type":"next","payload":{"data":{"noteAdded":null}}}"#)
        await until { live.events == 1 }
        #expect(state(live.stream) == "open")

        server.send(#"{"id":"\#(first)","type":"complete"}"#)
        await until { !live.isActive }
        #expect(state(live.stream) == "ended")
        #expect(live.error == nil)

        live.retry()
        #expect(state(live.stream) == "connecting")
        #expect(live.isActive)
        await until { server.count(of: "subscribe") == 2 }
        let second = try #require(server.ids(of: "subscribe").last)
        server.send(#"{"id":"\#(second)","type":"error","payload":[{"message":"bad subscription","path":["noteAdded"],"extensions":{"code":"FORBIDDEN","retryAfter":30,"ratio":0.5,"flags":[true,null],"nested":{"a":"b"}}}]}"#)
        await until { !live.isActive }
        guard case .ended(.request(let errors)?) = live.stream else {
            Issue.record("expected the stream ended by a request failure, got \(state(live.stream))")
            _ = consume liveRetention
            return
        }
        #expect(errors.messages == ["bad subscription"])
        #expect(errors.errors.map(\.path) == ["noteAdded"])
        #expect(errors.errors.map(\.extensions) == [Self.extensions])
        #expect((live.error as? GraphQLErrors)?.messages == ["bad subscription"], "the error that ended the stream is the handle's error")
        #expect(live.resumptions == 0, "a request error is not reconnected")

        live.retry()
        #expect(state(live.stream) == "connecting", "a retry after a failure reads connecting again")
        await until { server.count(of: "subscribe") == 3 }
        _ = consume liveRetention
        #expect(state(live.stream) == "idle")
    }

    @Test("the socket closes when its last subscription ends, and an error frame's GraphQL errors are its messages")
    func socketLifetime() async throws {
        let server = try SocketServer()
        let socket = GraphQLTransportWebSocket(url: try await server.start())
        defer { server.stop() }
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, kind: TestNoteAdded.kind, document: TestNoteAdded.document, variables: value.variables)

        final class Outcome: @unchecked Sendable { var messages: [String]? }
        let outcome = Outcome()
        let failing = Task {
            do {
                for try await _ in socket.send(request) {}
            } catch {
                outcome.messages = (error as? GraphQLErrors)?.messages ?? ["\(error)"]
            }
        }
        await until { server.count(of: "subscribe") == 1 }
        let id = try #require(server.ids(of: "subscribe").first)
        server.send(#"{"id":"\#(id)","type":"error","payload":[{"message":"bad subscription","path":["noteAdded"]}]}"#)
        await until { outcome.messages != nil }
        #expect(outcome.messages == ["bad subscription"])
        await failing.value
        await until { server.closed == 1 }

        let reader = Task { for try await _ in socket.send(request) {} }
        await until { server.count(of: "subscribe") == 2 }
        reader.cancel()
        await until { server.count(of: "complete") == 1 }
        await until { server.closed == 2 }
    }

    @Test("a subscription that starts as the last one's socket closes keeps the socket it opens")
    func subscriptionAfterTheSocketCloses() async throws {
        /// What a reader saw: its payloads, and whether its stream ended.
        final class Reader: @unchecked Sendable {
            private let lock = NSLock()
            private var payloads = 0
            private var ended = false

            func receive() { lock.withLock { payloads += 1 } }
            func end() { lock.withLock { ended = true } }
            var received: Int { lock.withLock { payloads } }
            var finished: Bool { lock.withLock { ended } }
        }
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, kind: TestNoteAdded.kind, document: TestNoteAdded.document, variables: value.variables)
        // The closed socket's read fails a few milliseconds after the close,
        // and a subscription that opens a socket within them is the case, so
        // the sequence runs until one has met it or long enough that one
        // would have.
        for _ in 0..<40 {
            let server = try SocketServer()
            let socket = GraphQLTransportWebSocket(url: try await server.start())
            defer { server.stop() }
            let first = Task { for try await _ in socket.send(request) {} }
            await until { server.count(of: "subscribe") == 1 }
            first.cancel()
            await until { server.count(of: "complete") == 1 }

            let reader = Reader()
            let second = Task {
                do {
                    for try await _ in socket.send(request) { reader.receive() }
                } catch {}
                reader.end()
            }
            await until(timeout: .seconds(2)) { server.count(of: "subscribe") == 2 || reader.finished }
            if let id = server.ids(of: "subscribe").dropFirst().first {
                server.send(#"{"id":"\#(id)","type":"next","payload":{"data":{"noteAdded":null}}}"#)
            }
            await until(timeout: .seconds(2)) { reader.received == 1 || reader.finished }
            second.cancel()
            guard reader.received == 1, !reader.finished else {
                Issue.record("the second subscription ended before its event")
                break
            }
        }
    }

    @Test("two subscriptions sent at once on a fresh socket whose credentials take a while share one connection, each under its own id, and each receives its events")
    func concurrentSendsOnAFreshSocketShareOneConnection() async throws {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var payloads: [String: Int] = [:]

            func add(to reader: String) { lock.withLock { payloads[reader, default: 0] += 1 } }
            func count(of reader: String) -> Int { lock.withLock { payloads[reader] ?? 0 } }
        }
        let server = try SocketServer()
        let socket = GraphQLTransportWebSocket(url: try await server.start(), credentials: {
            // A suspension in the read, as a token refresh would make, during
            // which the other request reaches the socket.
            try await Task.sleep(for: .milliseconds(20))
            return ["Authorization": "Bearer token"]
        })
        defer { server.stop() }
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, kind: TestNoteAdded.kind, document: TestNoteAdded.document, variables: value.variables)
        let log = Log()
        let readers = ["first", "second"].map { reader in
            Task { for try await _ in socket.send(request) { log.add(to: reader) } }
        }
        defer { readers.forEach { $0.cancel() } }

        await until { server.count(of: "subscribe") == 2 }
        #expect(server.count(of: "connection_init") == 1, "one connection serves both")
        let ids = server.ids(of: "subscribe")
        #expect(Set(ids).count == 2, "each stream subscribes under its own id")
        for id in Set(ids) {
            server.send(#"{"id":"\#(id)","type":"next","payload":{"data":{"noteAdded":null}}}"#)
        }
        await until { log.count(of: "first") == 1 && log.count(of: "second") == 1 }
        #expect(server.count(of: "connection_init") == 1)
    }

    @Test("a subscription whose reader goes away before the connection is acknowledged closes the socket it opened, and leaves to another the socket they both wait on")
    func subscriptionEndedBeforeTheAcknowledgement() async throws {
        let value = TestNoteAdded(characterId: "1", connections: [])
        let request = Request(operationName: TestNoteAdded.name, kind: TestNoteAdded.kind, document: TestNoteAdded.document, variables: value.variables)

        // Alone, it closes the socket whether the acknowledgement never comes
        // or comes as the reader goes.
        for acknowledged in [false, true] {
            let server = try SocketServer(acknowledges: false)
            let socket = GraphQLTransportWebSocket(url: try await server.start())
            defer { server.stop() }
            let leaving = Task { for try await _ in socket.send(request) {} }
            await until { server.count(of: "connection_init") == 1 }
            leaving.cancel()
            if acknowledged { server.acknowledge() }
            await until { server.closed == 1 }
            #expect(server.count(of: "subscribe") == 0)
        }

        // Beside another that waits for the same acknowledgement, it leaves
        // the socket to that one.
        final class Reader: @unchecked Sendable {
            private let lock = NSLock()
            private var payloads = 0

            func receive() { lock.withLock { payloads += 1 } }
            var received: Int { lock.withLock { payloads } }
        }
        let server = try SocketServer(acknowledges: false)
        let socket = GraphQLTransportWebSocket(url: try await server.start())
        defer { server.stop() }
        let reader = Reader()
        let staying = Task { for try await _ in socket.send(request) { reader.receive() } }
        await until { server.count(of: "connection_init") == 1 }
        let leaving = Task { for try await _ in socket.send(request) {} }
        // Time for it to wait beside the first, as it would in an app.
        try await Task.sleep(for: .milliseconds(20))
        leaving.cancel()
        _ = await leaving.result
        server.acknowledge()
        await until { server.count(of: "subscribe") == 1 }
        let id = try #require(server.ids(of: "subscribe").first)
        server.send(#"{"id":"\#(id)","type":"next","payload":{"data":{"noteAdded":null}}}"#)
        await until { reader.received == 1 }
        #expect(server.count(of: "subscribe") == 1, "the one that went away subscribed nothing")
        #expect(server.closed == 0)
        staying.cancel()
        await until { server.closed == 1 }
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
        let request = Request(operationName: TestNoteAdded.name, kind: TestNoteAdded.kind, document: TestNoteAdded.document, variables: value.variables)
        let log = Log()
        let readers = Dictionary(uniqueKeysWithValues: ["first", "second"].map { reader in
            (reader, Task {
                for try await payload in socket.send(request) { log.add(payload, to: reader) }
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

    @Test("the multipart parser yields each part's body however the bytes are chunked, and drops a preamble")
    func multipart() {
        let body = "a preamble, which is no part\r\n---\r\nContent-Type: application/json\r\n\r\n{\"data\":{\"a\":1},\"hasNext\":true}\r\n---\r\nContent-Type: application/json\r\n\r\n{\"incremental\":[],\"hasNext\":false}\r\n-----\r\n"
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

    @Test("URLSessionTransport streams each part of a multipart response, answers once otherwise, and fails on an error status with its body", arguments: [
        ("multipart/mixed; boundary=\"-\"", 200, "\r\n---\r\n\r\n{\"data\":{},\"hasNext\":true}\r\n---\r\n\r\n{\"hasNext\":false}\r\n-----\r\n", ["{\"data\":{},\"hasNext\":true}", "{\"hasNext\":false}"]),
        ("application/json", 200, "{\"data\":{}}", ["{\"data\":{}}"]),
        ("application/json", 500, "down for maintenance", []),
    ])
    func urlSessionStreams(_ contentType: String, _ status: Int, _ body: String, _ parts: [String]) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedStub.self]
        configuration.httpAdditionalHeaders = ["X-Stub-Content-Type": contentType, "X-Stub-Status": String(status), "X-Stub-Body": Data(body.utf8).base64EncodedString()]
        let transport = URLSessionTransport(url: URL(string: "https://stub.invalid/graphql")!, session: URLSession(configuration: configuration))
        let request = Request(operationName: "Stub", kind: .query, document: .text("query Stub { a }"), variables: .none, incremental: true)
        var received: [String] = []
        do {
            for try await part in transport.send(request) { received.append(String(decoding: part, as: UTF8.self)) }
            #expect(status == 200)
        } catch let error as TransportError {
            #expect(error.statusCode == status)
            #expect(error.body == body)
        }
        #expect(received == parts)
    }

    @Test("a request with no response fails with an error that says what went wrong and names no HTTP status; one with an error status names it")
    func aFailureWithoutAResponse() async throws {
        let environment = Environment(transport: RecordedTransport())
        environment.log = nil
        let handle = environment.handle(for: TestList(page: 1))
        let retention = handle.retain()
        await handle.settle()
        guard case .failed(let error as TransportError) = handle.phase else {
            Issue.record("expected a transport error, got \(handle.phase)")
            return
        }
        #expect(error.statusCode == 0)
        #expect(error.description == "no recorded response for TestList")
        #expect(TransportError(statusCode: 502, body: "bad gateway").description == "HTTP 502: bad gateway")
        _ = consume retention
    }

    @Test("a recorded transport's requests, read while requests arrive off the main actor, are each time those sent so far, each read keeping the one before")
    func recordedRequestsReadWhileSent() async throws {
        let transport = RecordedTransport { _ in Data() }
        let count = 4_000
        let sending = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<count {
                    group.addTask {
                        _ = try? await transport.payload(Request(operationName: "Op\(index)", kind: .query, document: .text(""), variables: .none))
                    }
                }
            }
        }
        var previous: [String] = []
        while previous.count < count {
            let names = transport.requests.map(\.operationName)
            #expect(names.starts(with: previous))
            previous = names
            await Task.yield()
        }
        await sending.value
        #expect(Set(previous) == Set((0..<count).map { "Op\($0)" }))
    }
}

/// A server that answers with the status, content type and body its request's
/// headers name (the body in base64, as a header cannot hold a line break),
/// handed over three bytes at a time.
final class ChunkedStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Stub-Status") ?? "") ?? 200
        let contentType = request.value(forHTTPHeaderField: "X-Stub-Content-Type") ?? "application/json"
        let body = Data(base64Encoded: request.value(forHTTPHeaderField: "X-Stub-Body") ?? "") ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
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

/// What the compiler emits for an operation when `baton.json` names
/// `"onError": "NULL"`; the test target's configuration names none.
extension TestNullsOnError {
    public static let errorBehavior: ErrorBehavior? = .null
}
