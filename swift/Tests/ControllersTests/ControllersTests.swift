#if canImport(AppKit)
import AppKit
import Baton
import BatonSpec
import BatonTesting
import Controllers
import Foundation
import Observation
import Synchronization
import Testing

@MainActor
@Suite("AppKit controllers", .timeLimit(.minutes(1)))
struct ControllersTests {
    let header = Spec.data("rickandmorty/character-header-9.json")
    let page = Spec.data("rickandmorty/characters-page-1.json")
    /// How long a test waits for a render it expects not to come.
    let quiet = Duration.milliseconds(500)

    func rename(_ environment: Environment, id: String, to name: String) async throws {
        try await environment.commitPayload(CharacterQuery(id: id), Payload(json: #"{"data":{"character":{"id":"\#(id)","name":"\#(name)"}}}"#))
    }

    func environment(_ transport: RecordedTransport) -> Environment {
        let environment = Environment(transport: transport)
        environment.log = nil
        return environment
    }

    @Test func a_character_controller_renders_the_response_and_again_when_a_commit_renames_the_character() async throws {
        let environment = environment(RecordedTransport([CharacterQuery.name: header]))
        let controller = CharacterViewController(environment: environment, id: "9")
        controller.loadViewIfNeeded()

        #expect(await wait { controller.nameLabel.stringValue == "Agency Director" })
        #expect(controller.detailsLabel.stringValue == "Dead · Human")
        #expect(controller.originLabel.stringValue == "Origin: Earth (Replacement Dimension)")

        try await rename(environment, id: "9", to: "Director of the Agency")
        #expect(await wait { controller.nameLabel.stringValue == "Director of the Agency" })
        #expect(controller.detailsLabel.stringValue == "Dead · Human")
    }

    @Test func a_controller_whose_query_the_store_already_answers_renders_it_in_its_first_frame() async throws {
        let environment = environment(RecordedTransport([CharacterQuery.name: header]))
        let first = CharacterViewController(environment: environment, id: "9")
        first.loadViewIfNeeded()
        #expect(await wait { first.nameLabel.stringValue == "Agency Director" })

        let second = CharacterViewController(environment: environment, id: "9")
        second.loadViewIfNeeded()
        #expect(second.nameLabel.stringValue == "Agency Director", "the read is synchronous, so the first frame is not blank")
    }

    @Test func a_cell_renders_its_row_at_once_follows_a_rename_and_after_reuse_follows_nothing() async throws {
        let environment = environment(RecordedTransport([CharactersQuery.name: page]))
        let controller = CharactersViewController(environment: environment)
        controller.loadViewIfNeeded()
        #expect(await wait { controller.tableView.numberOfRows == 20 })

        let handle = environment.handle(for: CharactersQuery(page: 1))
        guard case .ready(let data) = handle.phase, let rick = data.characters?.results?.first?.characterCell else {
            Issue.record("expected the first page, got \(handle.phase)")
            return
        }
        let cell = CharacterCell()
        cell.bind(rick)
        #expect(cell.nameLabel.stringValue == "Rick Sanchez", "a bound cell renders in the call")
        #expect(cell.detailsLabel.stringValue == "Alive · Human")

        try await rename(environment, id: "1", to: "Rick C-137")
        #expect(await wait { cell.nameLabel.stringValue == "Rick C-137" })

        cell.prepareForReuse()
        let witness = CharacterCell()
        witness.bind(rick)
        try await rename(environment, id: "1", to: "Rick Sanchez")
        #expect(await wait { witness.nameLabel.stringValue == "Rick Sanchez" })
        let rendered = await wait(until: { cell.nameLabel.stringValue == "Rick Sanchez" }, timeout: quiet)
        #expect(!rendered, "a reused cell no longer renders the row it left")
    }

    @Test func the_tables_rows_are_not_read_again_when_a_commit_renames_a_character() async throws {
        let environment = environment(RecordedTransport([CharactersQuery.name: page]))
        let controller = CharactersViewController(environment: environment)
        controller.loadViewIfNeeded()
        #expect(await wait { controller.tableView.numberOfRows == 20 })

        let handle = environment.handle(for: CharactersQuery(page: 1))
        let changed = Mutex(false)
        withObservationTracking {
            _ = CharactersViewController.shown(handle.phase)
        } onChange: {
            changed.withLock { $0 = true }
        }
        try await rename(environment, id: "1", to: "Rick C-137")
        #expect(!changed.withLock { $0 }, "the rows read ids and lenses, not names")
    }

    @Test func activation_parks_a_hidden_app_resumes_an_unhidden_one_and_refetches_a_failed_query_on_return() async throws {
        let center = NotificationCenter()
        let transport = RecordedTransport()
        let environment = environment(transport)
        let activation = Activation(environment: environment, center: center)
        let controller = CharacterViewController(environment: environment, id: "9")
        controller.loadViewIfNeeded()
        #expect(await wait { !controller.errorLabel.stringValue.isEmpty }, "no recorded response, so the fetch fails")

        center.post(name: NSApplication.didHideNotification, object: nil)
        #expect(await wait { !environment.isActive })
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        #expect(await wait { environment.isActive })

        transport.record(CharacterQuery.name, header)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await wait { controller.nameLabel.stringValue == "Agency Director" })
        #expect(controller.errorLabel.isHidden)
        withExtendedLifetime(activation) {}
    }
}
#endif
