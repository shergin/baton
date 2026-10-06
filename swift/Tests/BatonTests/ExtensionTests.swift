@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import Testing

/// Client fields, from the schema extension in `spec/tests/extensions.graphql`:
/// a server's answer leaves them out and the operation is ready without them;
/// a payload committed by hand writes them, a lens reads them like any field,
/// and the image keeps them.
@MainActor
@Suite("Client schema extensions", .timeLimit(.minutes(1)))
struct ExtensionTests {
    /// The reads a store reported as missing, by record key and storage key.
    final class Misses: @unchecked Sendable {
        var reads: [String] = []
    }

    final class Counter: @unchecked Sendable {
        var fired = 0
    }

    /// Records every missing read of the store into `misses`.
    func reporting(into misses: Misses, _ store: Store) {
        store.log = { event in if case .missing(let type, let field) = event { misses.reads.append(type + "." + field) } }
    }

    func pinned(_ store: Store) throws -> TestPinnedCharacter.Data.Character {
        let data = TestPinnedCharacter.Data(anchor: Anchor(record: store.root, variables: TestPinnedCharacter(id: "1").variables, store: store))
        return try #require(data.character)
    }

    @Test("a server's answer without the client fields is ready, reads them as nil, and reports nothing missing")
    func aServerAnswerWithoutTheClientFieldsIsReady() async throws {
        let environment = Environment(transport: RecordedTransport([TestPinnedCharacter.name: fixture("pinned-character")]))
        let misses = Misses()
        reporting(into: misses, environment.store)
        let handle = environment.handle(for: TestPinnedCharacter(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        let character = try #require(data.character)
        #expect(character.name == "Rick Sanchez")
        #expect(character.isPinned == nil)
        #expect(character.note == nil)
        #expect(misses.reads.isEmpty, "a client field no payload wrote is absent by design: \(misses.reads)")
        let resolved = TestPinnedCharacter.plan.resolve(TestPinnedCharacter(id: "1").variables, in: environment.store.keys)
        if case .miss = environment.store.check(resolved) {
            Issue.record("the check waits for no client field")
        }
        _ = retention
    }

    @Test("reading a client field no payload wrote does not refetch the operation")
    func readingAnAbsentClientFieldDoesNotRefetch() async throws {
        let transport = RecordedTransport([TestPinnedCharacter.name: fixture("pinned-character")])
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestPinnedCharacter(id: "1"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected .ready, got \(handle.phase)")
            return
        }
        #expect(data.character?.isPinned == nil)
        await handle.settle()
        #expect(transport.requestCount == 1, "no server answers a client field, so none is asked again")
        _ = retention
    }

    @Test("a payload committed by hand writes the client fields, and only the body that reads the changed one re-evaluates")
    func aPayloadCommittedByHandWritesTheClientFields() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        environment.store.commit(try Ingest.normalize(fixture("pinned-character"), plan: TestPinnedCharacter.plan.resolve(TestPinnedCharacter(id: "1").variables, in: environment.store.keys)))
        let character = try pinned(environment.store)
        #expect(character.isPinned == nil)

        let pin = Counter()
        let server = Counter()
        withObservationTracking { _ = character.isPinned } onChange: { pin.fired += 1 }
        withObservationTracking {
            _ = character.name
            _ = character.status
        } onChange: { server.fired += 1 }

        try await environment.commitPayload(TestPinnedCharacter(id: "1"), fixture("pin-character"))
        #expect(character.isPinned == true)
        #expect(character.note == "the one who built the portal gun")
        #expect(pin.fired == 1)
        #expect(server.fired == 0, "the payload carries the same server fields, which change nothing")
    }

    @Test("the text a server receives leaves the client fields out, and an operation of a client list keeps its server field")
    func theTextLeavesTheClientFieldsOut() throws {
        let pinned = try #require(TestPinnedCharacter.text)
        let drafts = try #require(TestDrafts.text)
        #expect(pinned.contains("name"))
        #expect(pinned.contains("status"))
        #expect(!pinned.contains("isPinned"))
        #expect(!pinned.contains("note"))
        #expect(drafts.contains("character"))
        #expect(!drafts.contains("drafts"))
    }

    @Test("a draft's link to a character is the record a server's answer wrote, one record for both")
    func aDraftLinksTheServerCharacter() throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("drafts"), plan: TestDrafts.plan.resolve(TestDrafts().variables, in: store.keys)))
        let draft = try #require(store.existing("Draft:d1"))
        let character = try #require(store.existing("Character:1"))
        guard case .ref(let about) = draft.read(Registry.slot(Registry.type("Draft"), "about")) else {
            Issue.record("Draft:d1.about is not a link")
            return
        }
        #expect(about === character)

        let data = TestDrafts.Data(anchor: Anchor(record: store.root, variables: TestDrafts().variables, store: store))
        let drafts = try #require(data.drafts)
        let first = try #require(drafts.element(0))
        #expect(first.about?.recordID == data.character?.recordID)
        #expect(first.about?.name == "Rick Sanchez")
        #expect(drafts.element(1)?.about == nil)
    }

    @Test("client fields a payload wrote survive a relaunch from the image")
    func clientFieldsSurviveARelaunch() async throws {
        let image = TemporaryImage()
        let first = Environment(transport: SilentTransport(), store: Store(persistence: Persistence(url: image.url)))
        first.log = nil
        try await first.commitPayload(TestPinnedCharacter(id: "1"), fixture("pin-character"))
        await first.store.persistence?.close()

        let second = Environment(transport: SilentTransport(), store: Store(persistence: Persistence(url: image.url)))
        second.log = nil
        let handle = second.handle(for: TestPinnedCharacter(id: "1"), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the image to answer, got \(handle.phase)")
            return
        }
        #expect(data.character?.isPinned == true)
        #expect(data.character?.note == "the one who built the portal gun")
        await second.store.persistence?.close()
    }

    @Test("client records a client link reaches survive a relaunch from the image")
    func clientRecordsSurviveARelaunch() async throws {
        let image = TemporaryImage()
        let first = Environment(transport: SilentTransport(), store: Store(persistence: Persistence(url: image.url)))
        first.log = nil
        try await first.commitPayload(TestDrafts(), fixture("drafts"))
        await first.store.persistence?.close()

        let second = Environment(transport: SilentTransport(), store: Store(persistence: Persistence(url: image.url)))
        let misses = Misses()
        reporting(into: misses, second.store)
        let handle = second.handle(for: TestDrafts(), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the image to answer, got \(handle.phase)")
            return
        }
        #expect(data.drafts?.count == 2)
        #expect(data.drafts?.element(0)?.text == "Ask about the citadel")
        #expect(data.drafts?.element(0)?.about?.name == "Rick Sanchez")
        #expect(misses.reads.isEmpty, "\(misses.reads)")
        await second.store.persistence?.close()
    }

    @Test("a client field selected on an interface is not waited for on the concrete type a record has")
    func aClientFieldOnAnInterfaceIsNotWaitedFor() throws {
        let store = Store()
        store.log = nil
        let query = Registry.type("Query")
        let node = Registry.type("Node")
        let character = Registry.type("Character")
        let plan = Plan(root: Selection(type: query, key: [], fields: [
            .linked("probeNode", key: .fixed(Registry.slot(query, "probeNode")), plural: false, selection: Selection(type: node, key: ["id"], abstract: true, variants: [
                .init(types: nil, fields: [
                    .scalar("__typename", key: .fixed(Registry.slot(node, "__typename")), kind: .string, list: false),
                    .scalar("id", key: .fixed(Registry.slot(node, "id")), kind: .string, list: false),
                    .scalar("probeBookmarked", key: .fixed(Registry.slot(node, "probeBookmarked")), kind: .bool, list: false, client: true),
                ]),
            ])),
        ])).resolve(.none, in: store.keys)
        store.commit(try Ingest.normalize(Data(#"{"data":{"probeNode":{"__typename":"Character","id":"1"}}}"#.utf8), plan: plan))
        #expect(store.existing("Character:1")?.type == character)
        if case .miss = store.check(plan) {
            Issue.record("the check waits for a client field once it is resolved on the record's concrete type")
        }
    }
}
