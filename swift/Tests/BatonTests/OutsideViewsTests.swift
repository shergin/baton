@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Testing

/// What `docs/recipes/outside-views.md` says of code that is not a view: a
/// fetch commits and returns nothing, a `storeOnly` handle reads what the
/// store holds without a request, and a retention is what keeps it.
@MainActor
@Suite("Outside views")
struct OutsideViewsTests {
    func transport() -> RecordedTransport {
        RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")])
    }

    @Test func a_fetch_then_a_store_only_handle_reads_the_response_with_one_request() async throws {
        let transport = transport()
        let environment = Environment(transport: transport)
        environment.log = nil

        try await environment.fetch(TestHeaderQuery(id: "5"))
        let handle = environment.handle(for: TestHeaderQuery(id: "5"), fetchPolicy: .storeOnly)
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected the fetched data from the store, got \(handle.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Jerry Smith")
        #expect(transport.requestCount == 1, "the store-only handle sent nothing of its own")
    }

    @Test func a_store_only_handle_fails_with_missing_data_and_sends_nothing_when_the_store_cannot_answer() {
        let transport = transport()
        let environment = Environment(transport: transport)
        environment.log = nil

        let handle = environment.handle(for: TestHeaderQuery(id: "5"), fetchPolicy: .storeOnly)
        guard case .failed(let error) = handle.phase else {
            Issue.record("expected a failure, got \(handle.phase)")
            return
        }
        #expect(error is MissingDataError)
        #expect(transport.requestCount == 0)
    }

    @Test func a_fetched_operation_nothing_retains_is_collected_once_the_release_buffer_lets_it_go_and_a_retained_one_stays() async throws {
        let transport = RecordedTransport { request in
            guard case .string(let id)? = request.variables["id"] else { return nil }
            return fixture("character-header-\(id)")
        }
        let environment = Environment(transport: transport, store: Store(releaseBufferSize: 0))
        environment.log = nil

        let kept = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = kept.retain()
        await kept.settle()
        try await environment.fetch(TestHeaderQuery(id: "11"))
        environment.store.collect()

        #expect(environment.store.existing("Character:11") == nil, "the fetch nothing retained left with the empty buffer")
        #expect(environment.store.existing("Character:5") != nil, "the retained handle kept its records")
        guard case .ready(let data) = kept.phase else {
            Issue.record("expected the retained handle ready, got \(kept.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Jerry Smith")
        _ = consume retention
    }
}
