@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Synchronization
import Testing

/// The environment's log: what it hears of fetches, commits, field errors,
/// the image and missing data, and that it hears nothing once cleared.
@MainActor
@Suite("Log", .timeLimit(.minutes(1)))
struct LogTests {
    /// The events a log heard, in order. Locked, since the image's writer
    /// logs off the main actor.
    final class Events: Sendable {
        private let heard = Mutex<[LogEvent]>([])

        var all: [LogEvent] { heard.withLock { $0 } }

        /// A log that appends to the box.
        var log: @Sendable (LogEvent) -> Void {
            { event in self.heard.withLock { $0.append(event) } }
        }

        var fieldErrors: [String] {
            all.compactMap { event in
                guard case .fieldError(_, let path) = event else { return nil }
                return path
            }
        }

        var commits: [LogEvent.CommitKind] {
            all.compactMap { event in
                guard case .committed(let kind, _) = event else { return nil }
                return kind
            }
        }
    }

    /// A transport whose every request throws `error`.
    struct Throwing: Transport {
        let error: any Error & Sendable

        func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
            AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// The kind a fetch over a transport that throws `error` logs failing.
    func failureKind(of error: any Error & Sendable) async -> LogEvent.FailureKind? {
        let environment = Environment(transport: Throwing(error: error))
        let events = Events()
        environment.log = events.log
        _ = try? await environment.fetch(TestHeaderQuery(id: "5"))
        for case .fetchFailed(let operation, let kind) in events.all where operation == TestHeaderQuery.name {
            return kind
        }
        return nil
    }

    @Test("a fetch logs its start, the server commit with the slots it changed, and its completion with a duration, in that order and nothing else")
    func a_fetch_logs_its_start_its_commit_and_its_completion() async throws {
        let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")]))
        let events = Events()
        environment.log = events.log
        try await environment.fetch(TestHeaderQuery(id: "5"))

        let heard = events.all
        #expect(heard.count == 3, "\(heard)")
        guard heard.count == 3 else { return }
        #expect(heard[0] == .fetchStarted(operation: TestHeaderQuery.name))
        guard case .committed(kind: .server, let changed) = heard[1] else {
            Issue.record("expected a server commit, got \(heard[1])")
            return
        }
        #expect(changed > 0)
        guard case .fetchCompleted(let operation, let duration) = heard[2] else {
            Issue.record("expected the fetch's completion, got \(heard[2])")
            return
        }
        #expect(operation == TestHeaderQuery.name)
        #expect(duration > .zero)
    }

    @Test("a fetch whose transport throws logs its start and then its failure as the transport's")
    func a_fetch_the_transport_fails_logs_a_transport_failure() async {
        let environment = Environment(transport: Throwing(error: TransportError(statusCode: 503, body: "down")))
        let events = Events()
        environment.log = events.log
        await #expect(throws: TransportError.self) {
            try await environment.fetch(TestHeaderQuery(id: "5"))
        }
        #expect(events.all == [
            .fetchStarted(operation: TestHeaderQuery.name),
            .fetchFailed(operation: TestHeaderQuery.name, kind: .transport),
        ])
    }

    @Test("a fetch the server answers with errors and no data logs its failure as the request's")
    func a_request_error_logs_a_request_failure() async {
        let environment = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("not-authorized")]))
        let events = Events()
        environment.log = events.log
        await #expect(throws: GraphQLErrors.self) {
            try await environment.fetch(TestProfileQuery(id: "1"))
        }
        #expect(events.all == [
            .fetchStarted(operation: TestProfileQuery.name),
            .fetchFailed(operation: TestProfileQuery.name, kind: .request),
        ])
    }

    @Test("a failure's kind is cancelled for a cancellation, transport for a transport error or a URL error, request for GraphQL errors and environment for an environment error")
    func a_failures_kind_follows_the_error() async {
        #expect(await failureKind(of: CancellationError()) == .cancelled)
        #expect(await failureKind(of: TransportError(statusCode: 500, body: "down")) == .transport)
        #expect(await failureKind(of: URLError(.notConnectedToInternet)) == .transport)
        #expect(await failureKind(of: GraphQLErrors(messages: ["not authorized"])) == .request)
        #expect(await failureKind(of: EnvironmentError.gone) == .environment)
    }

    @Test("an optimistic mutation logs an optimistic commit when its layer is applied and a server commit when the response lands")
    func an_optimistic_mutation_logs_both_commits() async throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let transport = ScriptedTransport()
        let environment = Environment(transport: transport, store: store)
        let events = Events()
        environment.log = events.log
        let optimistic = TestSetFavorite.OptimisticResponse(setFavorite: .init(character: .init(id: "1", favorite: true)))
        let mutation = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true), optimistic: optimistic.variable) }
        await until { transport.held.count == 1 }
        #expect(events.commits == [.optimistic])
        guard case .committed(kind: .optimistic, let changed) = events.all.first else {
            Issue.record("expected the optimistic commit, got \(events.all)")
            return
        }
        #expect(changed > 0)

        try #require(transport.held.first).respond(fixture("set-favorite-1"))
        _ = try await mutation.value
        #expect(events.commits == [.optimistic, .server])
    }

    @Test("a deferred spread the server could not deliver logs each field error it sent once, at its response path", arguments: [
        ("character-deferred-2-failed", ["character"]),
        ("character-deferred-2-failed-twice", ["character", "character"]),
    ])
    func an_uncaught_failed_part_logs_each_error_once(_ failed: String, _ paths: [String]) async throws {
        let environment = Environment(transport: DeliveryTests.OpenParts([fixture("uncaught-part-1"), fixture(failed)]))
        let events = Events()
        environment.log = events.log
        try await environment.fetch(TestUncaughtPartQuery(id: "1"))
        #expect(events.fieldErrors == paths)
        #expect(events.all.filter { if case .fieldError(let operation, _) = $0 { operation != TestUncaughtPartQuery.name } else { false } }.isEmpty)
        guard case .fetchCompleted = events.all.last else {
            Issue.record("expected the fetch's completion after its field errors, got \(events.all)")
            return
        }
    }

    @Test("a deferred spread the server could not deliver at a record it selects nothing on logs the error it left unplaced")
    func an_unplaced_error_is_logged() async throws {
        let environment = Environment(transport: DeliveryTests.OpenParts([fixture("node-deferred-episode-1"), fixture("character-deferred-2-failed")]))
        let events = Events()
        environment.log = events.log
        try await environment.fetch(TestNodeDeferred(id: "1"))
        #expect(events.all.filter { if case .fieldError = $0 { true } else { false } } == [.fieldError(operation: TestNodeDeferred.name, path: "character")])
    }

    @Test("a field error under @catch is not logged")
    func a_caught_error_is_not_logged() async throws {
        let environment = Environment(transport: DeliveryTests.OpenParts([fixture("caught-part-1"), fixture("character-deferred-2-failed")]))
        let events = Events()
        environment.log = events.log
        try await environment.fetch(TestCaughtPartQuery(id: "1"))
        #expect(events.fieldErrors.isEmpty, "\(events.all)")
        guard case .fetchCompleted = events.all.last else {
            Issue.record("expected the fetch to complete, got \(events.all)")
            return
        }
    }

    @Test("a persistent environment logs the image opened at most once and every write with the batches it landed")
    func the_image_logs_its_open_and_its_writes() async throws {
        let image = TemporaryImage()
        let events = Events()
        let store = Store(persistence: Persistence(url: image.url))
        let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")]), store: store)
        environment.log = events.log
        try await environment.fetch(TestHeaderQuery(id: "5"))
        await environment.store.persistence?.flush()

        let heard = events.all
        // The writer may open the file before the log is set, so the open is
        // heard once at most.
        #expect(heard.filter { $0 == .imageOpened }.count <= 1, "\(heard)")
        let written = heard.compactMap { event -> Int? in
            guard case .imageWritten(let batches) = event else { return nil }
            return batches
        }
        #expect(!written.isEmpty, "\(heard)")
        #expect(written.allSatisfy { $0 >= 1 }, "an empty drain logs no write: \(heard)")
        #expect(!heard.contains(.imageUnavailable))
        #expect(!heard.contains(.imageWriteFailed))
        await environment.end()
    }

    @Test("end clears the log: the environment's log reads nil and later work logs nothing")
    func end_clears_the_log() async throws {
        let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")]))
        let events = Events()
        environment.log = events.log
        try await environment.fetch(TestHeaderQuery(id: "5"))
        let record = try #require(environment.store.existing("Character:5"))
        let heard = events.all.count
        #expect(heard > 0)

        await environment.end()
        #expect(environment.log == nil)
        #expect(environment.store.log == nil)
        _ = TestNotes_character(anchor: Anchor(record: record, variables: TestNotesQuery(id: "5").variables, store: environment.store)).notes
        environment.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: environment.store.keys)))
        await #expect(throws: EnvironmentError.self) {
            try await environment.fetch(TestHeaderQuery(id: "5"))
        }
        #expect(events.all.count == heard, "\(events.all.dropFirst(heard))")
    }

    @Test("a fetch in flight when the environment ends logs nothing after the end, though its response arrives")
    func a_fetch_answered_after_the_end_logs_nothing() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let environment = Environment(transport: transport)
        let events = Events()
        environment.log = events.log
        let fetch = Task { try await environment.fetch(TestHeaderQuery(id: "5")) }
        await until { transport.held.count == 1 }
        #expect(events.all == [.fetchStarted(operation: TestHeaderQuery.name)])

        await environment.end()
        let heard = events.all.count
        try #require(transport.held.first).respond(fixture("character-header-5"))
        _ = try? await fetch.value
        #expect(events.all.count == heard, "\(events.all.dropFirst(heard))")
    }

    @Test("a lens over a store logs a field it never received as missing by type and field, and a null in a non-null field as unexpected")
    func a_lens_logs_missing_and_unexpected_data() throws {
        let store = Store()
        let events = Events()
        store.log = events.log
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        let rick = try #require(store.existing("Character:1"))
        _ = TestNotes_character(anchor: Anchor(record: rick, variables: TestNotesQuery(id: "1").variables, store: store)).notes
        #expect(events.all.filter { if case .committed = $0 { false } else { true } } == [.missing(type: "Character", field: "__TestNotes_notes_connection")])

        let unexpected = Store()
        let heard = Events()
        unexpected.log = heard.log
        let query = TestNotesQuery(id: "1")
        unexpected.commit(try Ingest.normalize(fixture("notes-total-null"), plan: TestNotesQuery.plan.resolve(query.variables, in: unexpected.keys)))
        let character = try #require(TestNotesQuery.Data(anchor: Anchor(record: unexpected.root, variables: query.variables, store: unexpected)).character)
        #expect(character.testNotes.notes.totalCount == 0)
        #expect(heard.all.filter { if case .committed = $0 { false } else { true } } == [.unexpected(type: "NoteConnection", field: "totalCount")])
    }

    @Test("an environment whose log is nil fetches, commits and reads missing data without a log")
    func a_nil_log_is_silent() async throws {
        let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")]))
        environment.log = nil
        #expect(environment.log == nil)
        try await environment.fetch(TestHeaderQuery(id: "5"))
        let record = try #require(environment.store.existing("Character:5"))
        _ = TestNotes_character(anchor: Anchor(record: record, variables: TestNotesQuery(id: "5").variables, store: environment.store)).notes
        await #expect(throws: TransportError.self) {
            try await environment.fetch(TestProfileQuery(id: "1"))
        }
    }
}
