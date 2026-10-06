@_spi(Generated) import Baton
import BatonSpec
import BatonTesting
import CryptoKit
import Foundation
import SQLite3
import Testing

/// What the tests' `baton.json` keeps off the image: the type `Secret`,
/// whose records are never written nor linked from a row, and the root field
/// `Query.secrets`, whose cell, storage key and fetch stamp never are.
@MainActor
@Suite("Transient", .timeLimit(.minutes(1)))
struct TransientTests {
    let image = TemporaryImage()

    /// An environment over the image, as a launch of the app makes one.
    func launch(_ transport: any Transport = SilentTransport()) -> Environment {
        let store = Store(persistence: Persistence(url: image.url))
        store.log = nil
        return Environment(transport: transport, store: store)
    }

    /// A launch that fetches the operation from its recorded response, then
    /// writes what it owes the image and ends.
    func fetch<Op: Baton.Query>(_ operation: Op, _ response: String) async throws -> Environment {
        let environment = launch(RecordedTransport([Op.name: fixture(response)]))
        try await environment.fetch(operation)
        return environment
    }

    /// The first column of the first row a read-only query of the image
    /// returns, as an integer.
    func integer(_ text: String) -> Int64? {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(image.url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, text, -1, &statement, nil) == SQLITE_OK, "\(text)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    @Test("a flushed image holds no record of a transient type, no cell or name of a transient root field and no fetch stamp of an operation selecting one, and keeps the record beside them")
    func a_flushed_image_holds_nothing_transient_and_keeps_the_record_beside_it() async throws {
        let environment = try await fetch(TestSecrets(code: "x"), "secrets")
        let data = TestSecrets.Data(anchor: Anchor(record: environment.store.root, variables: TestSecrets(code: "x").variables, store: environment.store))
        #expect(data.secrets?.count == 2, "memory reads the transient root field")
        #expect(data.secrets?.element(1)?.body == "where the citadel is")
        await environment.store.persistence?.close()

        #expect(integer("SELECT count(*) FROM records WHERE key LIKE 'Secret:%'") == 0)
        #expect(integer("SELECT count(*) FROM root WHERE field LIKE 'secrets%'") == 0)
        #expect(integer("SELECT count(*) FROM names WHERE name LIKE 'secrets(%'") == 0)
        #expect(integer("SELECT count(*) FROM fetches WHERE operation LIKE 'TestSecrets%'") == 0)
        #expect(integer("SELECT count(*) FROM fetches") == 0)
        #expect(integer("SELECT count(*) FROM records WHERE key = 'Character:1'") == 1)
        #expect(integer("SELECT count(*) FROM root WHERE field LIKE 'character(%'") == 1)
    }

    @Test("a transient root field whose value links nothing transient is kept off the image by the rules its plan carries")
    func a_transient_root_field_linking_nothing_transient_is_kept_off_the_image() async throws {
        let environment = launch()
        let response = Data(#"{"data":{"secrets":null,"character":{"id":"1","name":"Rick Sanchez"}}}"#.utf8)
        let operation = TestSecrets(code: "x")
        environment.store.commit(try Ingest.normalize(response, plan: TestSecrets.plan.resolve(operation.variables, in: environment.store.keys)))
        await environment.store.persistence?.close()

        #expect(integer("SELECT count(*) FROM root WHERE field LIKE 'secrets%'") == 0, "the null cell, which carries the code, is not written")
        #expect(integer("SELECT count(*) FROM names WHERE name LIKE 'secrets(%'") == 0)
        #expect(integer("SELECT count(*) FROM fetches WHERE operation LIKE 'TestSecrets%'") == 0)
        #expect(integer("SELECT count(*) FROM root WHERE field LIKE 'character(%'") == 1)
    }

    @Test("an operation that links a transient record but selects no transient root field leaves its fetch stamp")
    func an_operation_selecting_no_transient_root_field_leaves_its_fetch_stamp() async throws {
        let environment = try await fetch(TestCharacterSecret(), "character-secret")
        await environment.store.persistence?.close()

        #expect(integer("SELECT count(*) FROM fetches WHERE operation LIKE 'TestCharacterSecret%'") == 1)
    }

    @Test("a record's slot linking a transient record is left out of its row, so a relaunch misses and loads while the record's other fields hydrate")
    func a_slot_linking_a_transient_record_is_left_out_of_its_row() async throws {
        let first = try await fetch(TestCharacterSecret(), "character-secret")
        let data = TestCharacterSecret.Data(anchor: Anchor(record: first.store.root, variables: TestCharacterSecret().variables, store: first.store))
        #expect(data.character?.secret?.body == "the portal gun's fluid", "memory reads the transient record")
        await first.store.persistence?.close()

        #expect(integer("SELECT count(*) FROM records WHERE key = 'Character:1'") == 1)
        #expect(integer("SELECT count(*) FROM records WHERE key LIKE 'Secret:%'") == 0)
        #expect(integer("SELECT count(*) FROM names WHERE name = 'secret'") == 0, "no row names the slot")

        let second = launch()
        let plan = TestCharacterSecret.plan.resolve(TestCharacterSecret().variables, in: second.store.keys)
        #expect(second.store.check(plan) == .miss)
        let handle = second.handle(for: TestCharacterSecret())
        guard case .loading = handle.phase else {
            Issue.record("expected .loading, got \(handle.phase)")
            return
        }
        let stored = TestCharacterSecret.Data(anchor: Anchor(record: second.store.root, variables: TestCharacterSecret().variables, store: second.store))
        #expect(stored.character?.name == "Rick Sanchez", "the row hydrates without its transient slot")
        #expect(stored.character?.secret == nil)
        await second.store.persistence?.close()
    }

    @Test("a relaunch after an operation selecting a transient root field misses and loads")
    func a_relaunch_after_a_transient_root_field_misses() async throws {
        let first = try await fetch(TestSecrets(code: "x"), "secrets")
        await first.store.persistence?.close()

        let second = launch()
        let plan = TestSecrets.plan.resolve(TestSecrets(code: "x").variables, in: second.store.keys)
        #expect(second.store.check(plan) == .miss)
        let handle = second.handle(for: TestSecrets(code: "x"))
        guard case .loading = handle.phase else {
            Issue.record("expected .loading, got \(handle.phase)")
            return
        }
        await second.store.persistence?.close()
    }

    @Test("the schema's digest folds in the configuration and is not the digest of the schema's text alone")
    func the_digest_is_not_the_schema_text_alone() {
        let schema = Spec.data("tests/schema.graphql")
        let digest = Insecure.MD5.hash(data: schema).map { String(format: "%02x", $0) }.joined()
        #expect(Types.schemaDigest.count == 32)
        #expect(Types.schemaDigest != digest)
    }
}
