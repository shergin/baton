@_spi(Generated) import Baton
import BatonSpec
import BatonTesting
import Foundation
import Observation
import Testing

/// Whether a character is a series regular: alive, and seen in more than ten
/// episodes. A rule of the app's own, written against the value an
/// `@inline` fragment compiles to, so a test gives it a value built by hand.
func isSeriesRegular(_ character: TestCharacterValue_character) -> Bool {
    character.status == "Alive" && character.episode.count > 10
}

/// The values `@inline` fragments compile to, read out of a store through
/// the spread's accessor: what they hold, that they do not follow the store,
/// equality and hashing by value, the crossing of an isolation boundary,
/// what a read registers, and every form a spread takes.
@MainActor
@Suite("Inline values", .timeLimit(.minutes(1)))
struct InlineTests {
    // MARK: The recorded responses, as the values hold them

    /// A character of the recorded first page, the fields
    /// `TestCharacterValue_character` selects.
    struct RecordedCharacter: Decodable {
        struct Location: Decodable {
            let id: String?
            let name: String?
            let dimension: String?
        }

        struct Episode: Decodable {
            let id: String?
            let name: String?
        }

        let id: String?
        let name: String?
        let status: String?
        let origin: Location?
        let episode: [Episode]

        /// The value the fragment's fields make, built by its memberwise
        /// initializer.
        var value: TestCharacterValue_character {
            TestCharacterValue_character(
                id: id,
                name: name,
                status: status,
                origin: origin.map { origin in
                    .init(testOriginValue: TestOriginValue_location(id: origin.id, name: origin.name, dimension: origin.dimension))
                },
                episode: episode.map { TestCharacterValue_character.Episode(id: $0.id, name: $0.name) }
            )
        }
    }

    struct RecordedPage: Decodable {
        struct Payload: Decodable {
            struct Characters: Decodable {
                let results: [RecordedCharacter]
            }

            let characters: Characters
        }

        let data: Payload
    }

    /// The character `id` of a response in the shape of the recorded first
    /// page.
    func recorded(_ id: String, in response: Data = fixtureData) throws -> RecordedCharacter {
        let page = try JSONDecoder().decode(RecordedPage.self, from: response)
        return try #require(page.data.characters.results.first { $0.id == id })
    }

    // MARK: Stores

    /// A store that has committed `response`, the recorded first page by
    /// default, through the query that recorded it.
    func fixtureStore(_ response: Data = fixtureData) throws -> Store {
        let store = Store()
        try commit(response, into: store)
        return store
    }

    /// Commits a response in the shape of the recorded first page.
    func commit(_ response: Data, into store: Store) throws {
        let query = Fixture(page: 1)
        store.commit(try Ingest.normalize(response, plan: Fixture.plan.resolve(query.variables, in: store.keys)))
    }

    /// The recorded first page with every occurrence of `old` replaced by
    /// `new`.
    func edited(_ old: String, _ new: String) -> Data {
        Data(String(decoding: fixtureData, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
    }

    /// The lens that spreads the character's value, made over the record.
    func card(_ id: String, in store: Store) throws -> TestCard_character {
        TestCard_character(anchor: Anchor(record: try #require(store.existing("Character:\(id)")), variables: .none, store: store))
    }

    func counter(_ body: @escaping @MainActor () -> Void) -> (fired: () -> Int, track: () -> Void) {
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        func track() {
            withObservationTracking { body() } onChange: { counter.fired += 1 }
        }
        return ({ counter.fired }, track)
    }

    // MARK: What a value holds

    @Test("a value holds the recorded response at every path: its scalars, the nested origin value through its spread, and the episodes in order")
    func aValueHoldsTheResponse() throws {
        let store = try fixtureStore()
        let rick = try recorded("1")
        let value = try card("1", in: store).testCharacterValue
        #expect(value == rick.value)
        #expect(value.name == rick.name)
        #expect(value.status == rick.status)
        #expect(value.origin?.testOriginValue.dimension == rick.origin?.dimension)
        #expect(value.episode.map(\.name) == rick.episode.map(\.name))
        #expect(value.episode.count == rick.episode.count)

        // A character whose origin the response states as unknown.
        let morty = try recorded("2")
        #expect(try card("2", in: store).testCharacterValue == morty.value)
    }

    @Test("a commit that changes a field changes what the lens reads and not a value already taken")
    func aValueDoesNotFollowTheStore() throws {
        let store = try fixtureStore()
        let lens = try card("1", in: store)
        let taken = lens.testCharacterValue
        let response = edited(#""name":"Rick Sanchez""#, #""name":"Rick C-137""#)
        try commit(response, into: store)
        #expect(lens.name == "Rick C-137")
        #expect(lens.testCharacterValue.name == "Rick C-137")
        #expect(lens.testCharacterValue == (try recorded("1", in: response)).value)
        #expect(taken.name == "Rick Sanchez", "the value is the record as it was at the read")
        #expect(taken == (try recorded("1")).value)
    }

    @Test("two values read at one instant are equal and hash equal, a read after a change is not equal, and a value built by hand equals a read one")
    func aValueIsEqualByValue() throws {
        let store = try fixtureStore()
        let lens = try card("1", in: store)
        let first = lens.testCharacterValue
        let second = lens.testCharacterValue
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
        #expect(Set([first, second]).count == 1)
        #expect(first == (try recorded("1")).value, "the memberwise initializer builds the value a read does")

        try commit(edited(#""name":"Rick Sanchez","status":"Alive""#, #""name":"Rick Sanchez","status":"Dead""#), into: store)
        let changed = lens.testCharacterValue
        #expect(changed != first)
        #expect(changed.status == "Dead")
        #expect(Set([first, changed]).count == 2)
    }

    @Test("a value read on the main actor is handed to a detached task and read there")
    func aValueCrossesAnIsolationBoundary() async throws {
        let store = try fixtureStore()
        let value = try card("1", in: store).testCharacterValue
        let rick = try recorded("1")
        let read = await Task.detached {
            (value.name, value.origin?.testOriginValue.name, value.episode.map(\.name))
        }.value
        #expect(read.0 == rick.name)
        #expect(read.1 == rick.origin?.name)
        #expect(read.2 == rick.episode.map(\.name))
    }

    // MARK: What a read registers

    @Test("a body that calls the spread's accessor is invalidated when a field inside the value changes, and when a field of its nested origin value does")
    func theAccessorRegistersTheValuesReads() throws {
        let store = try fixtureStore()
        let lens = try card("1", in: store)
        let (fired, track) = counter { _ = lens.testCharacterValue }

        track()
        try commit(edited(#""name":"Rick Sanchez","status":"Alive""#, #""name":"Rick Sanchez","status":"Dead""#), into: store)
        #expect(fired() == 1, "the status is a field of the value")

        track()
        try commit(
            edited(
                #""name":"Earth (C-137)","type":"Planet","dimension":"Dimension C-137""#,
                #""name":"Earth (C-137)","type":"Planet","dimension":"Dimension C-138""#
            ),
            into: store
        )
        #expect(fired() == 2, "the origin's dimension is a field of the nested value")
        #expect(lens.testCharacterValue.origin?.testOriginValue.dimension == "Dimension C-138")
    }

    @Test("a value taken outside any tracking scope registers nothing: a body that reads only its fields is not invalidated by a change")
    func aValueTakenOutsideTrackingRegistersNothing() throws {
        let store = try fixtureStore()
        let taken = try card("1", in: store).testCharacterValue
        let (fired, track) = counter {
            _ = taken.name
            _ = taken.status
            _ = taken.origin?.testOriginValue.dimension
        }
        track()
        try commit(edited(#""name":"Rick Sanchez","status":"Alive""#, #""name":"Rick C-137","status":"Dead""#), into: store)
        #expect(fired() == 0, "the value's fields are stored properties, not reads of the store")
        #expect(taken.name == "Rick Sanchez")
    }

    // MARK: The spread's forms

    @Test("a conditional spread with arguments is nil when excluded, and when included reads the link under the bound argument")
    func aConditionalSpreadWithArguments() async throws {
        let environment = Environment(transport: SilentTransport())
        environment.log = nil
        // The notes under the fragment's default count, two, and under the
        // count the spread binds, one: three and five notes.
        try await environment.commitPayload(TestNoteCounts(page: 1, count: 2), fixture("note-counts-1"))
        try await environment.commitPayload(TestInlineQuery(id: "1", withNotes: true), fixture("notes-page-1"))
        let store = environment.store

        let included = TestInlineQuery(id: "1", withNotes: true)
        let character = try #require(TestInlineQuery.Data(anchor: Anchor(record: store.root, variables: included.variables, store: store)).character)
        let notes = try #require(character.notesValue)
        #expect(notes.notes.totalCount == 5, "the value reads notes(first: 1), not notes(first: 2)")
        #expect(notes == TestNotesValue_character(notes: .init(totalCount: 5)))
        #expect(character.testCard.name == "Rick Sanchez")

        let excluded = TestInlineQuery(id: "1", withNotes: false)
        let without = try #require(TestInlineQuery.Data(anchor: Anchor(record: store.root, variables: excluded.variables, store: store)).character)
        #expect(without.notesValue == nil, "the condition excludes the spread though the store holds its notes")
    }

    @Test("a deferred spread's value is nil before the deferred part arrives and the value after it")
    func aDeferredSpread() async throws {
        // The deferred part carries the recorded character; the initial part
        // carries only what the query selects outside the deferred spread.
        let page = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        let results = ((page?["data"] as? [String: Any])?["characters"] as? [String: Any])?["results"] as? [[String: Any]]
        let character = try #require(results?.first { $0["id"] as? String == "1" })
        let initial = Data(#"{"data":{"character":{"id":"1"}},"hasNext":true}"#.utf8)
        let deferred = try JSONSerialization.data(withJSONObject: [
            "incremental": [["data": character, "path": ["character"], "label": "TestDeferredValueQuery$defer$TestCharacterValue_character"]],
            "hasNext": false,
        ])
        let transport = DeliveryTests.GatedParts(initial, deferred)
        let environment = Environment(transport: transport)
        environment.log = nil
        let handle = environment.handle(for: TestDeferredValueQuery(id: "1"))
        let retention = handle.retain()
        await until { if case .loading = handle.phase { false } else { true } }
        guard case .ready(let first) = handle.phase else {
            Issue.record("expected the first part, got \(handle.phase)")
            return
        }
        #expect(first.character?.id == "1")
        #expect(first.character?.testCharacterValue == nil, "the deferred part has not arrived")

        transport.release()
        await handle.settle()
        guard case .ready(let whole) = handle.phase else {
            Issue.record("expected the whole response, got \(handle.phase)")
            return
        }
        #expect(whole.character?.testCharacterValue == (try recorded("1")).value)
        _ = consume retention
    }

    @Test("a caught spread is a success holding the value when nothing errored and a failure carrying the field error of a nested link's field")
    func aCaughtSpread() throws {
        let store = try fixtureStore()
        let query = TestCaughtValueQuery(id: "1")
        let character = TestCaughtValueQuery.Data.Character(anchor: Anchor(record: try #require(store.existing("Character:1")), variables: query.variables, store: store))
        let expected: Result<TestCharacterValue_character, FieldErrors> = .success(try recorded("1").value)
        #expect(character.caughtValue == expected)

        let hidden = TestCaughtValueQuery(id: "2")
        let errored = Store()
        errored.log = nil
        errored.commit(try Ingest.normalize(fixture("strict-episodes-2-hidden"), plan: TestCaughtValueQuery.plan.resolve(hidden.variables, in: errored.keys)))
        let data = TestCaughtValueQuery.Data(anchor: Anchor(record: errored.root, variables: hidden.variables, store: errored))
        let caught = try #require(data.character?.caughtValue)
        let failure: Result<TestCharacterValue_character, FieldErrors> = .failure(FieldErrors([FieldError(message: "name hidden", path: "character.episode.0.name")]))
        #expect(caught == failure)
    }

    @Test("under @throwOnFieldError a value reads a decimal, a date that converts, a list by the list rule and a caught field as a Result")
    func mappedScalarsInAValue() throws {
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("asset-list"), plan: TestAssetsQuery.plan.resolve(TestAssetsQuery().variables, in: store.keys)))
        store.commit(try Ingest.normalize(fixture("asset-prices"), plan: TestAssetPricesQuery.plan.resolve(TestAssetPricesQuery().variables, in: store.keys)))
        let data = TestAssetValuesQuery.Data(anchor: Anchor(record: store.root, variables: TestAssetValuesQuery().variables, store: store))
        let assets = try #require(data.assets)

        let portalGun = try #require(assets.element(0)).testAssetValue
        #expect(portalGun == TestAssetValue_asset(
            uuid: "a1",
            name: "Portal gun",
            price: Decimal(scalarText: "12345678901234567890.123456789"),
            listedAt: Date(scalarText: "2026-10-11T09:30:00.250Z"),
            page: URL(scalarText: "https://example.com/assets/a1"),
            prices: ["1.50", "2", "0.001"].map { Decimal(scalarText: $0) },
            caughtSize: .success(3)
        ))
        #expect(portalGun.price == Decimal(string: "12345678901234567890.123456789", locale: Locale(identifier: "en_US_POSIX")))
        #expect(portalGun.listedAt?.scalarText == "2026-10-11T09:30:00.250Z")

        // b2's price is `n/a`, its page empty and c3's date `yesterday`: none
        // converts, so the spread throws and no value is built with a zero in
        // its place.
        do {
            let value = try #require(assets.element(1)).testAssetValue
            Issue.record("b2's price does not convert, yet the value was built: \(value)")
        } catch let error as FieldErrors {
            #expect(error.errors == [FieldError.conversion(path: "price", to: Decimal.self), FieldError.conversion(path: "page", to: URL.self)])
        }
        do {
            let value = try #require(assets.element(2)).testAssetValue
            Issue.record("c3's date does not convert, yet the value was built: \(value)")
        } catch let error as FieldErrors {
            #expect(error.errors == [FieldError.conversion(path: "listedAt", to: Date.self)])
        }

        // With b2's price one that converts and its empty page a null, its
        // list keeps the list rule: an element that does not convert reads
        // nil beside the null.
        let priced = try Oracle.replacing(
            "assets.1.page",
            with: .null,
            in: try Oracle.replacing("assets.1.price", with: .string("4.50"), in: fixture("asset-prices"))
        )
        store.commit(try Ingest.normalize(priced, plan: TestAssetPricesQuery.plan.resolve(TestAssetPricesQuery().variables, in: store.keys)))
        let plumbus = try #require(assets.element(1)).testAssetValue
        #expect(plumbus.price == Decimal(scalarText: "4.50"))
        #expect(plumbus.prices == [Decimal(scalarText: "3.25"), nil, nil])
        #expect(plumbus.page == nil)
        #expect(plumbus.caughtSize == .success(1))
    }

    @Test("a caught field inside a value under @throwOnFieldError is a failure carrying its error and does not make the spread throw")
    func aCaughtFieldInAValue() throws {
        var response = try #require(try JSONSerialization.jsonObject(with: fixture("asset-list")) as? [String: Any])
        var payload = try #require(response["data"] as? [String: Any])
        var assets = try #require(payload["assets"] as? [[String: Any]])
        assets[0]["size"] = NSNull()
        payload["assets"] = assets
        response["data"] = payload
        response["errors"] = [["message": "size unavailable", "path": ["assets", 0, "size"]]]
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("asset-prices"), plan: TestAssetPricesQuery.plan.resolve(TestAssetPricesQuery().variables, in: store.keys)))
        store.commit(try Ingest.normalize(try JSONSerialization.data(withJSONObject: response), plan: TestAssetsQuery.plan.resolve(TestAssetsQuery().variables, in: store.keys)))
        let data = TestAssetValuesQuery.Data(anchor: Anchor(record: store.root, variables: TestAssetValuesQuery().variables, store: store))
        let value = try #require(data.assets?.element(0)).testAssetValue
        #expect(value.uuid == "a1")
        #expect(value.caughtSize == .failure(FieldErrors([FieldError(message: "size unavailable", path: "assets.0.size")])))
    }

    @Test("a value on a union sets the type condition the record satisfies: a character's, a location's, and neither for an episode")
    func aValueOnAUnion() throws {
        struct RecordedResult: Decodable {
            let __typename: String
            let name: String?
            let status: String?
            /// `TestUnion` reads a location's dimension under this alias.
            let label: String?
        }
        struct RecordedSearch: Decodable {
            struct Payload: Decodable { let search: [RecordedResult] }
            let data: Payload
        }
        let recorded = try JSONDecoder().decode(RecordedSearch.self, from: fixture("union-1")).data.search
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("union-1"), plan: TestUnion.plan.resolve(TestUnion(name: "a").variables, in: store.keys)))
        let query = TestResultValuesQuery(name: "a")
        let results = try #require(TestResultValuesQuery.Data(anchor: Anchor(record: store.root, variables: query.variables, store: store)).search)
        #expect(results.count == 3)
        #expect(recorded.map(\.__typename) == ["Character", "Location", "Episode"])

        let character = results[0].testResultValue
        #expect(character.asCharacter == TestResultValue_searchResult.AsCharacter(name: recorded[0].name, status: recorded[0].status))
        #expect(character.asLocation == nil)

        let location = results[1].testResultValue
        #expect(location.asLocation == TestResultValue_searchResult.AsLocation(name: recorded[1].name, dimension: recorded[1].label))
        #expect(location.asCharacter == nil)

        let episode = results[2].testResultValue
        #expect(episode == TestResultValue_searchResult(asCharacter: nil, asLocation: nil))
    }

    // MARK: The errors of the values a value spreads

    @Test("a caught spread is a failure carrying the field error of a value its value spreads")
    func aCaughtSpreadSeesTheErrorsOfTheValuesItsValueSpreads() throws {
        let hidden = TestCaughtValueQuery(id: "2")
        let store = Store()
        store.log = nil
        store.commit(try Ingest.normalize(fixture("strict-origin-2-hidden"), plan: TestCaughtValueQuery.plan.resolve(hidden.variables, in: store.keys)))
        let data = TestCaughtValueQuery.Data(anchor: Anchor(record: store.root, variables: hidden.variables, store: store))
        let caught = try #require(data.character?.caughtValue)
        let failure: Result<TestCharacterValue_character, FieldErrors> = .failure(FieldErrors([FieldError(message: "name hidden", path: "character.origin.name")]))
        #expect(caught == failure, "the origin's name is read through the spread of `TestOriginValue_location`")
    }

    @Test("a value under @throwOnFieldError throws an error of a value it spreads under a condition that holds, reads in the scope of a spread's arguments, and leaves a caught spread's errors to it")
    func aThrowingValueCollectsTheValuesItSpreads() throws {
        let store = Store()
        store.log = nil
        let shown = TestScanningValueQuery(id: "1", withName: true)
        let plan = TestScanningValueQuery.plan.resolve(shown.variables, in: store.keys)
        // The notes under the count the spread binds, then a name the server
        // hid.
        store.commit(try Ingest.normalize(fixture("notes-page-1"), plan: plan))
        store.commit(try Ingest.normalize(fixture("character-name-hidden"), plan: plan))
        let hiddenName = FieldError(message: "name hidden", path: "character.name")

        let withName = try #require(TestScanningValueQuery.Data(anchor: Anchor(record: store.root, variables: shown.variables, store: store)).character)
        #expect(throws: FieldErrors([hiddenName]), "the named value is spread and its name errored") {
            try withName.testScanningValue
        }

        let skipped = TestScanningValueQuery(id: "1", withName: false)
        let withoutName = try #require(TestScanningValueQuery.Data(anchor: Anchor(record: store.root, variables: skipped.variables, store: store)).character)
        let value = try withoutName.testScanningValue
        #expect(value.named == nil)
        #expect(value.testNotesValue.notes.totalCount == 5, "the notes are read under notes(first: 1)")
        guard case .failure(let caught) = value.caughtCharacter else {
            Issue.record("the caught value's name errored, got \(value.caughtCharacter)")
            return
        }
        #expect(caught.errors.contains(hiddenName), "the caught spread keeps the error the outer value left to it")
    }

    // MARK: A rule tested with a value

    @Test("a rule over a value is tested with a value built by hand and holds for one read from the store")
    func aRuleTestedWithAValue() throws {
        let regular = TestCharacterValue_character(
            id: "1",
            name: "Rick Sanchez",
            status: "Alive",
            origin: nil,
            episode: (1...11).map { TestCharacterValue_character.Episode(id: "\($0)", name: nil) }
        )
        #expect(isSeriesRegular(regular))
        let gone = TestCharacterValue_character(id: "1", name: "Rick Sanchez", status: "Dead", origin: nil, episode: regular.episode)
        #expect(!isSeriesRegular(gone))
        let guest = TestCharacterValue_character(id: "1", name: "Rick Sanchez", status: "Alive", origin: nil, episode: Array(regular.episode.prefix(1)))
        #expect(!isSeriesRegular(guest))

        let store = try fixtureStore()
        #expect(isSeriesRegular(try card("1", in: store).testCharacterValue), "the recorded Rick is alive and in more than ten episodes")
    }
}
