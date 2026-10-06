@_spi(Generated) import Baton
import Foundation
import Testing

@MainActor
@Suite("A concrete lens under an abstract selection", .timeLimit(.minutes(1)))
struct ConditionLensTests {
    @Test("a concrete lens reads the fields of an interface condition its type satisfies, and the interface's own lens still reads them")
    func concreteLensReadsTheInterfaceFields() throws {
        let search = TestUnion(name: "a")
        let store = Store()
        final class Misses: @unchecked Sendable { var types: [String] = [] }
        let misses = Misses()
        store.log = { event in if case .missing(let type, _) = event { misses.types.append(type) } }
        store.commit(try Ingest.normalize(fixture("union-1"), plan: TestUnion.plan.resolve(search.variables, in: store.keys)))
        let results = try #require(TestUnion.Data(anchor: Anchor(record: store.root, variables: search.variables, store: store)).search)
        #expect(results[0].asCharacter?.name == "Rick Sanchez")
        #expect(results[0].asCharacter?.label == "Rick Sanchez", "the alias still reads the character's name")
        #expect(results[1].asLocation?.name == "Earth (C-137)", "the name is the location's own, not the alias's dimension")
        #expect(results[1].asLocation?.label == "Dimension C-137")
        #expect(results[2].asEpisode?.air_date == "December 2, 2013", "an Episode is not Named and its lens has no name")
        #expect(results[0].asNamed?.name == "Rick Sanchez")
        #expect(results[1].asNamed?.name == "Earth (C-137)")
        #expect(misses.types.isEmpty, "\(misses.types)")
    }

    @Test("each concrete lens of a union reads the field of the interface every member implements")
    func everyConcreteLensReadsTheInterfaceField() throws {
        let store = Store()
        let query = TestSpellings()
        store.commit(try Ingest.normalize(fixture("spellings-1"), plan: TestSpellings.plan.resolve(query.variables, in: store.keys)))
        let spellings = try #require(TestSpellings.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).spellings)
        #expect(spellings[0].asBaton?.label == "the module")
        #expect(spellings[1].asType?.label == "not a metatype")
        #expect(spellings[2].asProtocol?.label == "not a protocol")
        #expect(spellings[3].asSet?.label == "not a set")
        #expect(spellings[4].asAny?.label == "not any type")
        #expect(spellings.map { $0.asSpelled?.label } == ["the module", "not a metatype", "not a protocol", "not a set", "not any type", nil])
    }
}
