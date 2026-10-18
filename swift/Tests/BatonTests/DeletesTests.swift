@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import Testing

/// A transport that answers the notes query, the assets query and the two
/// discards with their recorded responses.
func discardsTransport() -> RecordedTransport {
    RecordedTransport([
        TestNotesQuery.name: notesPage(1),
        TestAssetsQuery.name: fixture("asset-list"),
        TestDiscardNote.name: fixture("discard-note-n2"),
        TestDiscardAsset.name: fixture("discard-asset-a1"),
    ])
}

@MainActor
@Suite("A mutation names the record it deletes", .timeLimit(.minutes(1)))
struct DeletesTests {
    /// The notes query, fetched and held as a view on screen holds it.
    func notes(in environment: Environment) async throws -> (TestNotes_character, Retention) {
        let handle = environment.handle(for: TestNotesQuery(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase, let character = data.character?.testNotes else {
            throw TransportError(statusCode: 0, body: "the first page did not arrive")
        }
        return (character, retention)
    }

    /// The assets query, fetched and held as a view on screen holds it.
    func assets(in environment: Environment) async throws -> (TestAssetsQuery.Data, Retention) {
        let handle = environment.handle(for: TestAssetsQuery())
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            throw TransportError(statusCode: 0, body: "the assets did not arrive")
        }
        return (data, retention)
    }

    @Test("a mutation that names the record it deletes by a variable removes it from a connection and from a plain list a view reads, and each body that read them is evaluated once")
    func aDeletionByVariableLeavesTheLists() async throws {
        let environment = Environment(transport: discardsTransport())
        environment.log = nil
        let (character, notesRetention) = try await notes(in: environment)
        let (assets, assetsRetention) = try await assets(in: environment)
        #expect(character.notes.nodes.map(\.id) == ["n1", "n2"])
        #expect(assets.assets?.map(\.name) == ["Portal gun", "Plumbus"])

        let connectionBody = Notifications()
        connectionBody.track { _ = character.notes.nodes }
        let discarded = try await environment.mutate(TestDiscardNote(id: "n2"))
        #expect(discarded.discardNote?.deleted == true)
        #expect(connectionBody.fired == 1, "the body that read the connection is told once")
        #expect(character.notes.nodes.map(\.id) == ["n1"])
        #expect(try #require(environment.store.existing("Note:n2")).deleted)

        let listBody = Notifications()
        listBody.track { _ = assets.assets }
        connectionBody.track { _ = character.notes.nodes }
        _ = try await environment.mutate(TestDiscardAsset(uuid: "a1"))
        #expect(listBody.fired == 1, "the body that read the list is told once")
        #expect(assets.assets?.map(\.name) == ["Plumbus"])
        #expect(try #require(environment.store.existing("Asset:a1")).deleted)
        #expect(connectionBody.fired == 1, "a deletion elsewhere tells the connection's body nothing")
        withExtendedLifetime((notesRetention, assetsRetention)) {}
    }

    @Test("an optimistic response's deletion shows in the turn of the call, and a transport failure reverts it so the record reads again")
    func anOptimisticDeletionIsRevertedByAFailure() async throws {
        let transport = GatedPages()
        let environment = Environment(transport: transport)
        environment.log = nil
        let (character, retention) = try await notes(in: environment)
        let second = try #require(character.notes.nodes.last)
        #expect(second.text == "Portal gun needs charging")
        // The body is told while the layer applies, inside the call: the
        // request that follows it has not reached the transport yet.
        final class Told: @unchecked Sendable { var pendingRequests: [Int] = [] }
        let told = Told()
        withObservationTracking { _ = character.notes.nodes } onChange: { told.pendingRequests.append(transport.gate.pending) }

        // The response carries nothing: what is deleted is the variable's.
        let discarding = Task { try await environment.mutate(TestDiscardNote(id: "n2"), optimistic: TestDiscardNote.OptimisticResponse().payload) }
        await until { transport.gate.pending != 0 }
        #expect(told.pendingRequests == [0], "the body was told before the request went out")
        #expect(character.notes.nodes.map(\.id) == ["n1"])
        #expect(second.text == nil)

        let body = Notifications()
        body.track { _ = character.notes.nodes }
        transport.gate.fail(TransportError(statusCode: 500, body: "no"))
        await #expect(throws: TransportError.self) { try await discarding.value }
        #expect(body.fired == 1, "the revert tells the body again")
        #expect(character.notes.nodes.map(\.id) == ["n1", "n2"])
        #expect(second.text == "Portal gun needs charging")
        #expect(environment.store.optimisticLayers.isEmpty)
        withExtendedLifetime(retention) {}
    }

    @Test("an optimistic deletion the server's answer resolves stays deleted, whatever the answer's boolean says")
    func theAnswerDoesNotGateTheDeletion() async throws {
        let transport = GatedPages()
        let environment = Environment(transport: transport)
        environment.log = nil
        let (character, retention) = try await notes(in: environment)
        let discarding = Task { try await environment.mutate(TestDiscardNote(id: "n1"), optimistic: TestDiscardNote.OptimisticResponse(discardNote: .init(deleted: true)).payload) }
        await until { transport.gate.pending != 0 }
        #expect(character.notes.nodes.map(\.id) == ["n2"])

        let body = Notifications()
        body.track { _ = character.notes.nodes }
        transport.gate.respond(TestDiscardNote.OptimisticResponse(discardNote: .init(deleted: false)).payload.bytes)
        let answered = try await discarding.value
        #expect(answered.discardNote?.deleted == false)
        #expect(body.fired == 0, "the server's commit replaces the layer with the same deletion")
        #expect(character.notes.nodes.map(\.id) == ["n2"])
        #expect(try #require(environment.store.existing("Note:n1")).deleted)
        #expect(environment.store.optimisticLayers.isEmpty)
        withExtendedLifetime(retention) {}
    }

    @Test("a payload committed by hand for the mutation deletes the record its variable names")
    func commitPayloadDeletes() async throws {
        let environment = Environment(transport: discardsTransport())
        environment.log = nil
        let (character, notesRetention) = try await notes(in: environment)
        let (assets, assetsRetention) = try await assets(in: environment)

        try await environment.commitPayload(TestDiscardNote(id: "n2"), Payload(fixture("discard-note-n2")))
        #expect(character.notes.nodes.map(\.id) == ["n1"])

        // A payload that answers nothing of the selection deletes as well.
        try await environment.commitPayload(TestDiscardAsset(uuid: "a1"), TestDiscardAsset.OptimisticResponse().payload)
        #expect(assets.assets?.map(\.name) == ["Plumbus"])
        #expect(try #require(environment.store.existing("Asset:a1")).deleted)
        withExtendedLifetime((notesRetention, assetsRetention)) {}
    }

    @Test("a record the mutation names that only the image holds is forgotten in the image, so neither this launch nor the next reads it back")
    func aDeletionOfARecordOnlyTheImageHolds() async throws {
        let image = TemporaryImage()
        func launch() -> Environment {
            let environment = Environment(transport: discardsTransport(), store: Store(persistence: Persistence(url: image.url)))
            environment.log = nil
            return environment
        }
        let plan = { (store: Store) in TestNotesQuery.plan.resolve(TestNotesQuery(id: "1").variables, in: store.keys) }

        let first = launch()
        first.store.commit(try Ingest.normalize(notesPage(1), plan: plan(first.store)))
        await first.store.persistence?.close()

        // The image answers the notes query before the deletion.
        let control = launch()
        #expect(control.store.check(plan(control.store)) == .image)
        await control.store.persistence?.close()

        let second = launch()
        #expect(second.store.existing("Note:n2") == nil, "memory does not hold it")
        _ = try await second.mutate(TestDiscardNote(id: "n2"))
        #expect(second.store.check(plan(second.store)) == .miss, "this launch reads no row of it")
        await second.store.persistence?.close()

        let third = launch()
        #expect(third.store.check(plan(third.store)) == .miss, "nor does the next, which fetches rather than show the deleted note")
        await third.store.persistence?.close()
    }

    @Test("the keys a plan's deletions name are composed from the variables, a String key and an Int key as they are, and an unset or null variable names none")
    func deletionKeysAreComposedFromTheVariables() {
        #expect(TestDiscardNote.plan.deletionKeys(TestDiscardNote(id: "n2").variables) == ["Note:n2"])
        #expect(TestDiscardAsset.plan.deletionKeys(TestDiscardAsset(uuid: "a1").variables) == ["Asset:a1"])
        #expect(TestDiscardNote.plan.deletionKeys(Variables(["id": .null])).isEmpty)
        #expect(TestDiscardNote.plan.deletionKeys(.none).isEmpty)
        #expect(TestDeleteNote.plan.deletionKeys(TestDeleteNote(id: "n2").variables).isEmpty, "@deleteRecord names its record in the payload")

        let plan = Plan(root: TestDiscardNote.plan.root, deletions: [
            Deletion(type: Types.Note, variable: "id"),
            Deletion(type: Types.Character, variable: "character"),
            Deletion(type: Types.Asset, variable: "uuid"),
        ])
        #expect(plan.deletionKeys(Variables(["id": .string("n1"), "character": .int(7), "uuid": .null])) == ["Note:n1", "Character:7"])
    }
}
