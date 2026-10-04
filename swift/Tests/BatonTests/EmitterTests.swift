@_spi(Generated) import Baton
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

    @Test("a field and an aliased selection named like a type condition's accessor keep their names, and the condition's accessor and lens take the next number")
    func conditionNames() throws {
        let store = Store()
        let data = TestConditionNames.Data(anchor: try root(TestConditionNames(id: "1", name: "Rick"), "condition-names-1", in: store))
        let namesake = try #require(data.namesake)
        #expect(namesake.asCharacter == "Rick Sanchez")
        let character: TestConditionNames.Data.Namesake.AsCharacter2? = namesake.asCharacter2
        #expect(character?.status == "Alive")
        let node = try #require(data.node)
        let episode: TestConditionNames.Data.Node.AsCharacter? = node.asCharacter
        #expect(episode == nil, "the aliased selection is on Episode")
        #expect(node.asCharacter2?.name == "Rick Sanchez")
    }

    @Test("fields named like a fragment and a refetch query the lens refers to get lenses of other names, and the spread and the refetch still name theirs")
    func programNames() throws {
        let store = Store()
        let data = TestProgramNamesQuery.Data(anchor: try root(TestProgramNamesQuery(id: "1"), "program-names-1", in: store))
        let fragment = try #require(data.character?.testProgramNames)
        let origin: TestProgramNames_character.TestProgramNamesRefetchQueryLens? = fragment.testProgramNamesRefetchQuery
        #expect(origin?.name == "Earth (C-137)")
        let location: TestProgramNames_character.TestCaughtProfile_characterLens? = fragment.testCaughtProfile_character
        #expect(location?.name == "Citadel of Ricks")
        let profile: TestCaughtProfile_character = fragment.testCaughtProfile
        #expect(profile.name == "Rick Sanchez")
        #expect(profile.origin?.name == "Earth (C-137)")
        #expect(TestProgramNames_character.refetchable.identifier == "id")
    }

    @Test("a field named like a spread's accessor keeps its name, and the spread's accessor takes the fragment's whole name")
    func spreadNames() throws {
        let store = Store()
        let data = TestSpreadNames.Data(anchor: try root(TestSpreadNames(id: "1"), "spread-names-1", in: store))
        let character = try #require(data.character)
        #expect(character.testCaughtStrict == "Human")
        #expect(try character.testCaughtStrict_character.species == "Human")
    }

    @Test("a connection whose edges' lens takes another name reads its nodes through that lens")
    func edgesNames() throws {
        let store = Store()
        let data = TestEdgesNamesQuery.Data(anchor: try root(TestEdgesNamesQuery(id: "1"), "edges-names-1", in: store))
        let notes = try #require(data.character?.testEdgesNames.notes)
        let nodes: [TestEdgesNames_character.Notes.Edges3.Node] = notes.nodes
        #expect(nodes.map(\.text) == ["Wubba lubba dub dub", "Portal gun needs charging"])
        #expect(notes.Edges.hasNextPage == true)
        #expect(notes.hasNext == true)
    }

    @Test("payload fields named like the types an optimistic builder spells get builders of other names, which render and apply, and a variable named self is one")
    func builderNames() throws {
        let store = Store()
        store.reportMissing = nil
        let mutation = TestBuilderNames(id: "1", favorite: true, self: "1")
        #expect(mutation.`self` == "1")
        #expect(mutation.variables == Variables(["id": .string("1"), "favorite": .bool(true), "self": .string("1")]))
        #expect(mutation == TestBuilderNames(id: "1", favorite: true, self: "1"))
        #expect(mutation != TestBuilderNames(id: "1", favorite: true, self: "2"))
        #expect(Set([mutation, TestBuilderNames(id: "1", favorite: true, self: "2")]).count == 2)
        let optimistic = TestBuilderNames.OptimisticResponse(
            type: .init(character: .init(id: "1", favorite: true)),
            self: .init(character: .init(id: "1", favorite: true)),
            string: .init(character: .init(id: "1", name: "Rick Prime")),
            sendable: .init(character: .init(id: "1", favorite: true))
        )
        let favorite: Variable = .object(["character": .object(["id": .string("1"), "favorite": .bool(true)])])
        #expect(optimistic.variable == .object([
            "type": favorite,
            "self": favorite,
            "string": .object(["character": .object(["id": .string("1"), "name": .string("Rick Prime")])]),
            "sendable": favorite,
        ]))
        let json = Data(("{\"data\":" + optimistic.variable.json + "}").utf8)
        _ = store.applyOptimistic(try Ingest.normalize(json, plan: TestBuilderNames.plan.resolve(mutation.variables), rootKey: Store.mutationRootKey))
        let root = try #require(store.existing(Store.mutationRootKey))
        let data = TestBuilderNames.Data(anchor: Anchor(record: root, variables: mutation.variables, store: store))
        let renamed: TestBuilderNames.Data.StringLens? = data.string
        #expect(renamed?.character?.name == "Rick Prime")
        #expect(data.type?.character?.favorite == true)
        #expect(data.`self`?.character?.favorite == true)
        #expect(data.sendable?.character?.favorite == true)
    }

    @Test("an operation whose text holds a backslash before a hash compiles, and its text holds both as the document wrote them")
    func textWithBackslashBeforeHash() {
        #expect(TestEscapedText.text.contains(##"search(name: "\\#1")"##))
    }
}
