@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import Testing

/// What a model that is not a view saw through `Observations`, in order.
@MainActor
final class Yields<Element> {
    var values: [Element] = []
}

@MainActor
@Suite("Derived state", .timeLimit(.minutes(1)))
struct DerivedStateTests {
    /// How long a test waits for a yield it expects not to come.
    let quiet = Duration.milliseconds(500)

    func commit(_ environment: Environment, _ character: String) async throws {
        try await environment.commitPayload(TestHeaderQuery(id: "5"), Payload(json: #"{"data":{"character":{"id":"5",\#(character)}}}"#))
    }

    @Test func a_model_outside_views_observes_a_lens_field_through_Observations() async throws {
        let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")]))
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(data.character?.testHeader.name == "Jerry Smith")

        let yields = Yields<String?>()
        let names = Observations<String?, Never> {
            if case .ready(let data) = handle.phase { data.character?.testHeader.name } else { nil }
        }
        let model = Task { @MainActor in
            for await name in names { yields.values.append(name) }
        }
        // The phase alone, read without the lens: ready after ready is no
        // change, so a yield above comes from the field the closure read.
        let phases = Yields<String>()
        let phaseOnly = Observations<String, Never> {
            if case .ready = handle.phase { "ready" } else { "other" }
        }
        let phaseModel = Task { @MainActor in
            for await phase in phaseOnly { phases.values.append(phase) }
        }
        await until { yields.values.count == 1 && phases.values.count == 1 }
        #expect(yields.values == ["Jerry Smith"], "the first iteration yields the current value")

        try await commit(environment, #""name":"Jerry Prime""#)
        await until { yields.values.count == 2 }
        await wait(until: { yields.values.count > 2 }, timeout: quiet)
        #expect(yields.values == ["Jerry Smith", "Jerry Prime"], "a commit that changes the name yields it once")

        try await commit(environment, #""status":"Dead""#)
        let yielded = await wait(until: { yields.values.count > 2 }, timeout: quiet)
        #expect(!yielded, "a commit that changes another field of the record yields nothing, got \(yields.values)")
        #expect(yields.values == ["Jerry Smith", "Jerry Prime"])

        // The observer is still live: the silence above was the status, not
        // a loop that had stopped.
        try await commit(environment, #""name":"Jerry Smith""#)
        await until { yields.values.count == 3 }
        #expect(yields.values == ["Jerry Smith", "Jerry Prime", "Jerry Smith"])

        #expect(phases.values == ["ready"], "no commit changed the phase")
        model.cancel()
        phaseModel.cancel()
        _ = consume retention
    }

    @Test func a_derived_value_recomputes_once_per_commit_that_touched_what_it_read() async throws {
        let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: fixture("character-header-5")]))
        environment.log = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "5"))
        let retention = handle.retain()
        await handle.settle()

        final class Evaluations { var count = 0 }
        let evaluations = Evaluations()
        let yields = Yields<String>()
        let summaries = Observations<String, Never> {
            evaluations.count += 1
            guard case .ready(let data) = handle.phase, let header = data.character?.testHeader else { return "" }
            return "\(header.name ?? "?") (\(header.status ?? "?"))"
        }
        let model = Task { @MainActor in
            for await summary in summaries { yields.values.append(summary) }
        }
        await until { yields.values.count == 1 }
        #expect(yields.values == ["Jerry Smith (Alive)"])

        try await commit(environment, #""name":"Jerry Prime","status":"Dead""#)
        await until { yields.values.count == 2 }
        await wait(until: { yields.values.count > 2 }, timeout: quiet)
        #expect(yields.values == ["Jerry Smith (Alive)", "Jerry Prime (Dead)"], "one commit that changes both fields yields once")

        try await commit(environment, #""species":"Cronenberg""#)
        let yielded = await wait(until: { yields.values.count > 2 }, timeout: quiet)
        #expect(!yielded, "a commit to a field the closure did not read yields nothing, got \(yields.values)")
        #expect(evaluations.count == 2, "the closure ran once to start and once for the commit that changed both fields")

        model.cancel()
        _ = consume retention
    }
}

@Suite("Lens shape")
struct LensShapeTests {
    @Test func a_lens_is_one_anchor_in_size() {
        #expect(MemoryLayout<TestHeader_character>.size == MemoryLayout<Anchor>.size)
        #expect(MemoryLayout<TestHeaderQuery.Data>.size == MemoryLayout<Anchor>.size)
    }

    @Test func an_anchor_is_three_words() {
        #expect(MemoryLayout<Anchor>.size == 3 * MemoryLayout<Int>.size)
    }
}
