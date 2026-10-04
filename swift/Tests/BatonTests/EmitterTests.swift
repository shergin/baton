import Baton
import Foundation
import Testing

@MainActor
@Suite("Generated code", .timeLimit(.minutes(1)))
struct EmitterTests {
    /// The root lens of `query` over a store that holds the fixture `name`.
    func root<Query: Baton.Query>(_ query: Query, _ name: String, in store: Store) throws -> Anchor {
        store.reportMissing = nil
        store.commit(try Ingest.normalize(fixture(name), plan: Query.plan.resolve(query.variables)))
        return Anchor(record: store.root, variables: query.variables, store: store)
    }

    @Test("a spread alone under @catch reads its fragment when the fragment has no field errors, with an error policy of its own or without")
    func caughtSpreadWithoutErrors() throws {
        let store = Store()
        let data = TestCaughtSpreads.Data(anchor: try root(TestCaughtSpreads(id: "1"), "caught-spreads-1", in: store))
        let character = try #require(data.character)
        guard case .success(let profile) = character.profile else {
            Issue.record("expected the profile, got \(character.profile)")
            return
        }
        #expect(profile.name == "Rick Sanchez")
        #expect(profile.origin?.name == "Earth (C-137)")
        #expect(character.nulledProfile?.name == "Rick Sanchez")
        guard case .success(let strict) = character.strict else {
            Issue.record("expected the strict fragment, got \(character.strict)")
            return
        }
        #expect(strict.species == "Human")
        #expect(character.nulledStrict?.species == "Human")
        guard case .success(let onNode) = data.node?.profile else {
            Issue.record("expected the profile through the interface, got \(String(describing: data.node?.profile))")
            return
        }
        #expect(onNode?.name == "Rick Sanchez")
    }

    @Test("a spread alone under @catch reads the field errors in its fragment as the failure, and under @catch(to: NULL) as nil, with an error policy of its own or without")
    func caughtSpreadWithErrors() throws {
        let store = Store()
        let data = TestCaughtSpreads.Data(anchor: try root(TestCaughtSpreads(id: "1"), "caught-spreads-1-errors", in: store))
        let character = try #require(data.character)
        guard case .failure(let profile) = character.profile else {
            Issue.record("expected the error in the profile's origin, got \(character.profile)")
            return
        }
        #expect(profile.errors == [FieldError(message: "origin name redacted", path: "character.origin.name")])
        #expect(character.nulledProfile == nil)
        guard case .failure(let strict) = character.strict else {
            Issue.record("expected the error in the strict fragment, got \(character.strict)")
            return
        }
        #expect(strict.errors.map(\.path) == ["character.species"])
        #expect(character.nulledStrict == nil, "@catch(to: NULL) reads the errors as nil rather than throwing them")
        guard case .failure(let onNode) = data.node?.profile else {
            Issue.record("expected the error through the interface, got \(String(describing: data.node?.profile))")
            return
        }
        #expect(onNode.errors.map(\.path) == ["character.origin.name"])
    }
}
