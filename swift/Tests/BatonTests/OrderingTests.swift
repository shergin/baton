@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

/// The events a test listens for, as the log hands them over.
final class Superseded: @unchecked Sendable {
    var operations: [String] = []
}

@MainActor
@Suite("A late response yields", .timeLimit(.minutes(1)))
struct OrderingTests {
    /// The notes page as a server batch, normalized under the query's root.
    func notesChanges(_ store: Store) throws -> ChangeSet {
        try Ingest.normalize(notesPage(1), plan: TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: store.keys))
    }

    /// The name of `Character:1` as the notes query reads it from the store.
    func name(in environment: Environment) -> String? {
        let handle = environment.handle(for: TestNotesQuery(id: "1"), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else { return nil }
        return data.character?.testNotes.name
    }

    /// Starts a fetch of the notes query and waits until its request is held,
    /// so the requests are issued in the order of the calls.
    func startFetch(_ environment: Environment, _ transport: ScriptedTransport) async -> Task<Void, any Error> {
        let before = transport.held.count
        let fetch = Task { try await environment.fetch(TestNotesQuery(id: "1")) }
        await until { transport.held.count > before }
        return fetch
    }

    @Test("the store numbers each request its environment issues one more than the last, and a payload committed by hand issues none")
    func eachRequestIsNumberedOneMoreThanTheLast() async throws {
        let environment = Environment(transport: discardsTransport())
        environment.log = nil
        #expect(environment.store.generation == 0)
        try await environment.fetch(TestNotesQuery(id: "1"))
        #expect(environment.store.generation == 1)
        _ = try await environment.mutate(TestDiscardNote(id: "n2"))
        #expect(environment.store.generation == 2)
        try await environment.fetch(TestNotesQuery(id: "1"))
        #expect(environment.store.generation == 3)
        try await environment.commitPayload(TestNotesQuery(id: "1"), Payload(notesPage(1)))
        #expect(environment.store.generation == 3, "a payload committed by hand answers no request")
    }

    @Test("a record deleted while a request was current is not revived by a response to that request or an older one, and is revived by a response to a newer one")
    func aDeletionYieldsOnlyToANewerRequest() async throws {
        let environment = Environment(transport: discardsTransport())
        environment.log = nil
        try await environment.fetch(TestNotesQuery(id: "1"))
        _ = try await environment.mutate(TestDiscardNote(id: "n2"))
        let store = environment.store
        let deletedAt = store.generation
        let note = try #require(store.existing("Note:n2"))
        #expect(note.deleted)

        store.commit(try notesChanges(store), replacingOptimistic: nil, issued: deletedAt - 1)
        #expect(note.deleted, "a response to a request older than the deletion leaves the record deleted")
        store.commit(try notesChanges(store), replacingOptimistic: nil, issued: deletedAt)
        #expect(note.deleted, "a response to the request current at the deletion leaves the record deleted")
        store.commit(try notesChanges(store), replacingOptimistic: nil, issued: deletedAt + 1)
        #expect(!note.deleted, "a response to a newer request names the record again and revives it")
    }

    @Test("a payload that carries no request's number revives a deleted record, as a payload committed by hand does")
    func aPayloadWithoutANumberRevives() async throws {
        let environment = Environment(transport: discardsTransport())
        environment.log = nil
        try await environment.fetch(TestNotesQuery(id: "1"))
        _ = try await environment.mutate(TestDiscardNote(id: "n2"))
        let store = environment.store
        let note = try #require(store.existing("Note:n2"))
        #expect(note.deleted)

        store.commit(try notesChanges(store), replacingOptimistic: nil)
        #expect(!note.deleted)

        _ = try await environment.mutate(TestDiscardNote(id: "n2"))
        #expect(note.deleted)
        try await environment.commitPayload(TestNotesQuery(id: "1"), Payload(notesPage(1)))
        #expect(!note.deleted, "the environment's payload committed by hand revives it too")
    }

    @Test("a query's response to a request older than one whose response already landed for the same root is dropped at the door and logged as superseded")
    func anOlderResponseOfTheRootIsDropped() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestNotesQuery.name)
        let environment = Environment(transport: transport)
        let superseded = Superseded()
        environment.log = { event in if case .responseSuperseded(let operation) = event { superseded.operations.append(operation) } }

        let older = await startFetch(environment, transport)
        let newer = await startFetch(environment, transport)
        let held = transport.held
        try #require(held.count == 2)

        held[1].respond(fixture("notes-page-1-renamed"))
        try await newer.value
        #expect(name(in: environment) == "Rick C-137")
        #expect(superseded.operations.isEmpty)

        held[0].respond(notesPage(1))
        try await older.value
        #expect(name(in: environment) == "Rick C-137", "the older response does not overwrite the newer one")
        #expect(superseded.operations == [TestNotesQuery.name])
    }

    @Test("a root remembers the request of the last response committed for it, so a response newer than the first but older than the last is dropped")
    func theRootFollowsTheLastCommittedResponse() async throws {
        let transport = ScriptedTransport()
        transport.hold(TestNotesQuery.name)
        let environment = Environment(transport: transport)
        let superseded = Superseded()
        environment.log = { event in if case .responseSuperseded(let operation) = event { superseded.operations.append(operation) } }

        let first = await startFetch(environment, transport)
        let second = await startFetch(environment, transport)
        let third = await startFetch(environment, transport)
        let held = transport.held
        try #require(held.count == 3)

        held[0].respond(notesPage(1))
        try await first.value
        #expect(name(in: environment) == "Rick Sanchez")

        held[2].respond(fixture("notes-page-1-renamed"))
        try await third.value
        #expect(name(in: environment) == "Rick C-137", "a response newer than the last committed lands")
        #expect(superseded.operations.isEmpty)

        held[1].respond(notesPage(1))
        try await second.value
        #expect(name(in: environment) == "Rick C-137", "the second request is newer than the first response but older than the last")
        #expect(superseded.operations == [TestNotesQuery.name])
    }

    @Test("a mutation's response to an older request of the same operation and variables is committed after a newer one, since the rule is for a query's root")
    func anOlderMutationResponseIsNotDropped() async throws {
        let transport = ScriptedTransport([TestNotesQuery.name: notesPage(1)])
        let environment = Environment(transport: transport)
        let superseded = Superseded()
        environment.log = { event in if case .responseSuperseded(let operation) = event { superseded.operations.append(operation) } }
        try await environment.fetch(TestNotesQuery(id: "1"))
        #expect(name(in: environment) == "Rick Sanchez")

        let rename = TestRename(id: "1", name: "Rick Prime")
        let older = Task { _ = try await environment.mutate(rename) }
        await until { transport.held.count == 1 }
        let newer = Task { _ = try await environment.mutate(rename) }
        await until { transport.held.count == 2 }
        let held = transport.held

        held[1].respond(fixture("rename-1"))
        try await newer.value
        #expect(name(in: environment) == "Rick Prime")

        try await environment.fetch(TestNotesQuery(id: "1"))
        #expect(name(in: environment) == "Rick Sanchez")

        held[0].respond(fixture("rename-1"))
        try await older.value
        #expect(name(in: environment) == "Rick Prime", "the older mutation's response is committed")
        #expect(superseded.operations.isEmpty)
    }
}
