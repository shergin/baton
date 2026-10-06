@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

@MainActor
@Suite("Scripted transport", .timeLimit(.minutes(1)))
struct ScriptedTransportTests {
    /// A store holding the first page of the fixture through the list plan.
    func seededStore() throws -> Store {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables, in: store.keys)))
        return store
    }

    func favorite(_ store: Store, _ key: String) throws -> TestFavorite_character {
        TestFavorite_character(anchor: Anchor(record: try #require(store.existing(key)), variables: .none, store: store))
    }

    let optimistic = TestSetFavorite.OptimisticResponse(setFavorite: .init(character: .init(id: "1", favorite: true)))

    @Test("a mutation with no answer is held while its optimistic layer reads through a lens, and the response commits it and returns from mutate")
    func a_held_mutation_shows_its_layer_until_the_response_commits_it() async throws {
        let transport = ScriptedTransport()
        let environment = Environment(transport: transport, store: try seededStore())
        let rick = try favorite(environment.store, "Character:1")
        let mutation = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true), optimistic: optimistic.variable) }
        await until { transport.held.count == 1 }

        let held = try #require(transport.held.first)
        #expect(held.request.kind == .mutation)
        #expect(held.request.operationName == TestSetFavorite.name)
        #expect(rick.favorite == true, "the layer is visible while the mutation is held")
        #expect(environment.store.optimisticLayers.count == 1)

        held.respond(fixture("set-favorite-1"))
        let data = try await mutation.value
        #expect(data.setFavorite?.character?.name == "Rick Sanchez")
        #expect(rick.favorite == true)
        #expect(environment.store.optimisticLayers.isEmpty)
        #expect(transport.held.isEmpty, "an answered request leaves the list")
    }

    @Test("a held mutation the test refuses reverts its optimistic layer and mutate throws the error it was refused with")
    func a_refused_mutation_reverts_its_layer_and_throws_the_error() async throws {
        let transport = ScriptedTransport()
        let environment = Environment(transport: transport, store: try seededStore())
        let rick = try favorite(environment.store, "Character:1")
        let mutation = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true), optimistic: optimistic.variable) }
        await until { transport.held.count == 1 }
        #expect(rick.favorite == true)

        try #require(transport.held.first).refuse(TransportError(statusCode: 500, body: "refused"))
        do {
            _ = try await mutation.value
            Issue.record("a refused mutation returned")
        } catch let error as TransportError {
            #expect(error.statusCode == 500)
            #expect(error.body == "refused")
        }
        #expect(rick.favorite == nil, "the refusal reverted the layer")
        #expect(environment.store.optimisticLayers.isEmpty)
        #expect(transport.held.isEmpty)
    }

    @Test("a query answered from a fixture by its name is ready through a handle")
    func a_query_answered_by_name_is_ready_through_a_handle() async throws {
        let transport = ScriptedTransport()
        transport.answer(TestHeaderQuery.name, with: fixture("character-header-5"))
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Jerry Smith")
        #expect(transport.requestCount == 1)
        _ = consume retention
    }

    @Test("a query with no answer scripted fails its handle's fetch with a transport error of status 0 that names the operation")
    func a_query_with_no_answer_fails_with_a_transport_error_naming_it() async throws {
        let transport = ScriptedTransport()
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        await handle.settle()
        guard case .failed(let error as TransportError) = handle.phase else {
            Issue.record("expected a transport error, got \(handle.phase)")
            return
        }
        #expect(error.statusCode == 0)
        #expect(error.body.contains(TestHeaderQuery.name))
        #expect(transport.held.isEmpty, "a query is not held unless the test asks")
        _ = consume retention
    }

    @Test("a query the test holds by name waits until the test responds, and is then ready")
    func a_held_query_waits_for_the_response() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        await until { transport.held.count == 1 }
        #expect(transport.held.first?.request.kind == .query)
        guard case .loading = handle.phase else {
            Issue.record("expected loading while held, got \(handle.phase)")
            return
        }

        try #require(transport.held.first).respond(fixture("character-header-5"))
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Jerry Smith")
        #expect(transport.held.isEmpty)
        _ = consume retention
    }

    /// An environment whose queries and subscriptions both go to `transport`,
    /// and a subscription handle over `TestNoteAdded` in it.
    func subscription(_ transport: ScriptedTransport, line: Int = #line) -> (Environment, SubscriptionHandle<TestNoteAdded>) {
        let environment = Environment(transport: transport, subscriptions: transport)
        environment.log = nil
        let handle = environment.subscriptionHandle(for: TestNoteAdded(characterId: "scripted-\(line)", connections: []))
        return (environment, handle)
    }

    @Test("a subscription with no answer is driven by the test: two events arrive and completing the stream ends it with no failure and no resumption")
    func a_driven_subscription_receives_events_and_ends_when_completed() async throws {
        for named in [false, true] {
            let transport = ScriptedTransport()
            if named { transport.drive(TestNoteAdded.name) }
            let (environment, live) = subscription(transport)
            defer { withExtendedLifetime(environment) {} }
            let retention = live.retain()
            await until { transport.driven.count == 1 }
            let driven = try #require(transport.driven.first)
            #expect(driven.request.kind == .subscription)

            driven.send(fixture("note-added-1"))
            driven.send(fixture("note-added-2"))
            await until { live.events == 2 }
            driven.complete()
            await until { !live.isActive }
            guard case .ended(nil) = live.stream else {
                Issue.record("expected the stream ended with no failure, got \(live.stream)")
                return
            }
            #expect(live.resumptions == 0)
            #expect(transport.driven.isEmpty, "a completed stream leaves the list")
            _ = consume retention
        }
    }

    @Test("a driven stream that fails makes its subscription handle wait to reconnect")
    func a_driven_stream_that_fails_waits_to_reconnect() async throws {
        let transport = ScriptedTransport()
        let (environment, live) = subscription(transport)
        defer { withExtendedLifetime(environment) {} }
        let retention = live.retain()
        await until { transport.driven.count == 1 }
        try #require(transport.driven.first).fail(TransportError(statusCode: 502, body: "the stream broke"))
        await until {
            guard case .waiting = live.stream else { return false }
            return true
        }
        #expect(live.error is TransportError)
        #expect(transport.driven.isEmpty, "a failed stream leaves the list")
        _ = consume retention
    }

    @Test("the responder answers a request by its variables")
    func the_responder_answers_by_variables() async throws {
        let transport = ScriptedTransport { request in
            guard request.operationName == TestHeaderQuery.name, case .string(let id)? = request.variables["id"] else { return nil }
            return fixture("character-header-\(id)")
        }
        let environment = Environment(transport: transport)
        environment.log = nil
        let jerry = environment.handle(for: TestHeaderQuery(id: "5"))
        let einstein = environment.handle(for: TestHeaderQuery(id: "11"))
        let retentions = (jerry.retain(), einstein.retain())
        await jerry.settle()
        await einstein.settle()
        guard case .ready(let jerryData) = jerry.phase, case .ready(let einsteinData) = einstein.phase else {
            Issue.record("expected both ready, got \(jerry.phase) and \(einstein.phase)")
            return
        }
        #expect(jerryData.character?.testHeader.name == "Jerry Smith")
        #expect(einsteinData.character?.testHeader.name == "Albert Einstein")
        withExtendedLifetime(retentions) {}
    }

    @Test("the requests sent are listed in order, and listed by kind they partition into queries and mutations")
    func requests_by_kind_partition_the_requests_sent() async throws {
        let transport = ScriptedTransport([TestHeaderQuery.name: fixture("character-header-5"), TestSetFavorite.name: fixture("set-favorite-1")])
        let environment = Environment(transport: transport, store: try seededStore())
        try await environment.fetch(TestHeaderQuery(id: "5"))
        _ = try await environment.mutate(TestSetFavorite(id: "1", favorite: true))
        try await environment.fetch(TestHeaderQuery(id: "11"))

        #expect(transport.requestCount == 3)
        #expect(transport.requests.map(\.operationName) == [TestHeaderQuery.name, TestSetFavorite.name, TestHeaderQuery.name])
        let queries = transport.requests(of: .query)
        let mutations = transport.requests(of: .mutation)
        #expect(queries.map(\.operationName) == [TestHeaderQuery.name, TestHeaderQuery.name])
        #expect(mutations.map(\.operationName) == [TestSetFavorite.name])
        #expect(queries.count + mutations.count == transport.requestCount)
        #expect(transport.requests(of: .subscription).isEmpty)
        #expect(transport.held.isEmpty, "a mutation with an answer is not held")
    }

    /// Whether a task the test started has finished.
    final class Finished {
        var value = false
    }

    @Test("of two equal mutations held at once, responding to the second commits it alone and leaves the first pending in held, answerable through its entry")
    func responding_to_one_of_two_equal_held_mutations_leaves_the_other() async throws {
        let transport = ScriptedTransport()
        let environment = Environment(transport: transport, store: try seededStore())
        let firstFinished = Finished()
        let first = Task {
            defer { firstFinished.value = true }
            return try await environment.mutate(TestSetFavorite(id: "1", favorite: true))
        }
        await until { transport.held.count == 1 }
        let second = Task { try await environment.mutate(TestSetFavorite(id: "1", favorite: true)) }
        await until { transport.held.count == 2 }

        transport.held[1].respond(fixture("set-favorite-1"))
        let secondData = try await second.value
        #expect(secondData.setFavorite?.character?.favorite == true)
        await until { transport.held.count == 1 }
        #expect(!firstFinished.value, "the first mutation still waits for its answer")

        try #require(transport.held.first).respond(fixture("set-favorite-1"))
        let firstData = try await first.value
        #expect(firstData.setFavorite?.character?.favorite == true)
        #expect(transport.held.isEmpty)
    }

    @Test("of two equal held requests, the one whose consumer stops reading leaves held alone, and the other stays answerable")
    func a_dropped_consumer_forgets_only_its_own_held_request() async throws {
        let transport = ScriptedTransport()
        let request = Request(operationName: TestSetFavorite.name, kind: .mutation, document: .text("mutation TestSetFavorite { a }"), variables: .none)
        let firstStream = transport.send(request)
        let secondStream = transport.send(request)
        #expect(transport.held.count == 2)
        let first = Task {
            var iterator = firstStream.makeAsyncIterator()
            return try await iterator.next()
        }
        let second = Task {
            var iterator = secondStream.makeAsyncIterator()
            return try await iterator.next()
        }
        second.cancel()
        _ = try? await second.value
        await until { transport.held.count == 1 }

        let answer = fixture("set-favorite-1")
        try #require(transport.held.first).respond(answer)
        #expect(try await first.value == answer, "the entry left in held is the first request's")
        #expect(transport.held.isEmpty)
    }

    @Test("of two equal driven subscriptions, completing the second leaves the first in driven and still receiving events")
    func completing_one_of_two_equal_driven_streams_leaves_the_other() async throws {
        let transport = ScriptedTransport()
        let firstEnvironment = Environment(transport: transport, subscriptions: transport)
        let secondEnvironment = Environment(transport: transport, subscriptions: transport)
        firstEnvironment.log = nil
        secondEnvironment.log = nil
        defer { withExtendedLifetime((firstEnvironment, secondEnvironment)) {} }
        let operation = TestNoteAdded(characterId: "scripted-equal", connections: [])
        let firstLive = firstEnvironment.subscriptionHandle(for: operation)
        let firstRetention = firstLive.retain()
        await until { transport.driven.count == 1 }
        let secondLive = secondEnvironment.subscriptionHandle(for: operation)
        let secondRetention = secondLive.retain()
        await until { transport.driven.count == 2 }
        #expect(transport.driven[0].request.variables == transport.driven[1].request.variables)

        transport.driven[1].complete()
        await until { !secondLive.isActive }
        guard case .ended(nil) = secondLive.stream else {
            Issue.record("expected the second stream ended with no failure, got \(secondLive.stream)")
            return
        }
        #expect(transport.driven.count == 1)

        try #require(transport.driven.first).send(fixture("note-added-1"))
        await until { firstLive.events == 1 }
        #expect(secondLive.events == 0)
        #expect(firstLive.isActive, "the entry left in driven is the first stream's")
        _ = consume firstRetention
        _ = consume secondRetention
    }

    @Test("wait(until:) returns true once its condition holds and false when the timeout passes first")
    func wait_until_reports_whether_the_condition_held() async {
        let transport = ScriptedTransport()
        transport.hold(TestHeaderQuery.name)
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        #expect(await wait(until: { transport.held.count == 1 }))
        #expect(await wait(until: { transport.held.count == 2 }, timeout: .milliseconds(50)) == false)
        transport.held.first?.respond(fixture("character-header-5"))
        #expect(await wait(until: {
            guard case .ready = handle.phase else { return false }
            return true
        }))
        _ = consume retention
    }
}
