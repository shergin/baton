@_spi(Generated) import Baton
import BatonSpec
import Foundation

/// A manifest case bound to the operation value it names: the plan the
/// oracle walks, the variables it runs with, the text the compiler
/// generated, and the reads its generated lens gives, keyed by the
/// manifest's dotted paths. The reads go through `Data` alone and never
/// touch the plan, so a lens that disagrees with the store is caught.
struct OracleOperation: Sendable {
    typealias Reader = @MainActor @Sendable (Anchor) -> Manifest.Value
    typealias Spelling = @Sendable (Manifest.Value) -> Manifest.Value

    let name: String
    let text: String
    let plan: Plan
    let variables: Variables
    let readers: [String: Reader]
    /// The manifest's text at a path the lens reads as a mapped scalar,
    /// written again as the mapped type writes it, so that the response's
    /// `1.50` and the lens's `Decimal` 1.5 compare as one value.
    let spellings: [String: Spelling]
    /// Runs the operation through an environment, as an app fetches it;
    /// nil for an operation that is not a query.
    let fetch: (@MainActor @Sendable (Environment) async throws -> Void)?

    init<Op: Baton.Operation>(_ operation: Op, reads: [String: @MainActor @Sendable (Op.Data) -> Manifest.Value], spellings: [String: Spelling] = [:]) {
        self.spellings = spellings
        name = Op.name
        // The test target sets no `persistConfig`, so every operation holds its text.
        text = Op.text ?? ""
        plan = Op.plan
        variables = operation.variables
        readers = reads.mapValues { read -> Reader in { anchor in read(Op.Data(anchor: anchor)) } }
        if let query = operation as? any Query {
            fetch = { environment in try await environment.fetch(query) }
        } else {
            fetch = nil
        }
    }

    /// The operation each manifest case names, built from the case's
    /// variables. A case whose operation is missing here is a failure.
    static let bindings: [String: @Sendable (Manifest.Case) throws -> OracleOperation] = [
        "Fixture": { try OracleOperation(Fixture(page: $0.optionalInt("page")), reads: fixtureReads) },
        "TestEpisodesQuery": { try OracleOperation(TestEpisodesQuery(id: $0.string("id")), reads: episodesReads) },
        "TestHeaderQuery": { try OracleOperation(TestHeaderQuery(id: $0.string("id")), reads: headerReads) },
        "TestProfileQuery": { try OracleOperation(TestProfileQuery(id: $0.string("id")), reads: profileReads) },
        "TestStrictQuery": { try OracleOperation(TestStrictQuery(id: $0.string("id")), reads: strictReads) },
        "TestList": { try OracleOperation(TestList(page: $0.optionalInt("page")), reads: listReads) },
        "TestNotesQuery": { try OracleOperation(TestNotesQuery(id: $0.string("id")), reads: notesReads) },
        "TestNotesPaginationQuery": {
            try OracleOperation(TestNotesPaginationQuery(count: $0.optionalInt("count"), cursor: $0.optionalString("cursor"), id: $0.string("id")), reads: notesPaginationReads)
        },
        "TestAuthorNotesQuery": { try OracleOperation(TestAuthorNotesQuery(id: $0.string("id")), reads: authorNotesReads) },
        "TestRecentNotesQuery": { try OracleOperation(TestRecentNotesQuery(id: $0.string("id")), reads: recentNotesReads) },
        "TestRecentNotesPaginationQuery": {
            try OracleOperation(TestRecentNotesPaginationQuery(count: $0.optionalInt("count"), cursor: $0.optionalString("cursor"), id: $0.string("id")), reads: recentNotesPaginationReads)
        },
        "TestAddNoteNode": {
            try OracleOperation(TestAddNoteNode(characterId: $0.string("characterId"), text: $0.string("text"), connections: $0.strings("connections")), reads: addNoteNodeReads)
        },
        "TestAddNoteNodeFirst": {
            try OracleOperation(TestAddNoteNodeFirst(characterId: $0.string("characterId"), text: $0.string("text"), connections: $0.strings("connections")), reads: addNoteNodeFirstReads)
        },
        "TestKeys": { try OracleOperation(TestKeys(id: $0.string("id"), name: $0.optionalString("name")), reads: keysReads) },
        "TestConditions": {
            try OracleOperation(TestConditions(id: $0.string("id"), withOrigin: $0.bool("withOrigin"), hideStatus: $0.bool("hideStatus")), reads: conditionsReads)
        },
        "TestUnion": { try OracleOperation(TestUnion(name: $0.string("name")), reads: unionReads) },
        "TestNodeFields": { try OracleOperation(TestNodeFields(id: $0.string("id")), reads: nodeFieldsReads) },
        "TestNodeDeferred": { try OracleOperation(TestNodeDeferred(id: $0.string("id")), reads: nodeDeferredReads) },
        "TestTwoSpreads": { try OracleOperation(TestTwoSpreads(id: $0.string("id"), again: $0.bool("again")), reads: twoSpreadsReads) },
        "TestDeleteNote": { try OracleOperation(TestDeleteNote(id: $0.string("id")), reads: deleteNoteReads) },
        "TestAddNote": {
            try OracleOperation(TestAddNote(characterId: $0.string("characterId"), text: $0.string("text"), connections: $0.strings("connections")), reads: addNoteReads)
        },
        "TestAddNoteFirst": {
            try OracleOperation(TestAddNoteFirst(characterId: $0.string("characterId"), text: $0.string("text"), connections: $0.strings("connections")), reads: addNoteFirstReads)
        },
        "TestSearch": { try OracleOperation(TestSearch(name: $0.string("name")), reads: searchReads) },
        "TestSearchOrigins": { try OracleOperation(TestSearchOrigins(name: $0.string("name")), reads: searchOriginsReads) },
        "TestSetFavorite": { try OracleOperation(TestSetFavorite(id: $0.string("id"), favorite: $0.bool("favorite")), reads: setFavoriteReads) },
        "TestRename": { try OracleOperation(TestRename(id: $0.string("id"), name: $0.string("name")), reads: renameReads) },
        "TestRemoveNote": { try OracleOperation(TestRemoveNote(id: $0.string("id"), connections: $0.strings("connections")), reads: removeNoteReads) },
        "TestNoteAdded": { try OracleOperation(TestNoteAdded(characterId: $0.string("characterId"), connections: $0.strings("connections")), reads: noteAddedReads) },
        "TestTokenizerQuery": { _ in OracleOperation(TestTokenizerQuery(), reads: tokenizerReads) },
        "TestAssetsQuery": { _ in OracleOperation(TestAssetsQuery(), reads: assetsReads) },
        "TestAssetQuery": { try OracleOperation(TestAssetQuery(uuid: $0.string("uuid")), reads: assetReads) },
        "TestQuotesQuery": { _ in OracleOperation(TestQuotesQuery(), reads: quotesReads) },
        "TestQuoteQuery": { try OracleOperation(TestQuoteQuery(base: $0.string("base"), quote: $0.string("quote")), reads: quoteReads) },
        "TestAssetPricesQuery": { _ in OracleOperation(TestAssetPricesQuery(), reads: assetPricesReads, spellings: assetPricesSpellings) },
        "TestSetStatuses": { _ in OracleOperation(TestSetStatuses(), reads: setStatusesReads, spellings: setStatusesSpellings) },
        "TestPinnedCharacter": { try OracleOperation(TestPinnedCharacter(id: $0.string("id")), reads: pinnedCharacterReads) },
        "TestDrafts": { _ in OracleOperation(TestDrafts(), reads: draftsReads) },
        "TestSecrets": { try OracleOperation(TestSecrets(code: $0.string("code")), reads: secretsReads) },
        "TestCharacterSecret": { _ in OracleOperation(TestCharacterSecret(), reads: characterSecretReads) },
    ]

    /// Binds a manifest case to its operation.
    static func bind(_ entry: Manifest.Case) throws -> OracleOperation {
        guard let binding = bindings[entry.operation] else {
            throw OracleError(description: "no binding for the operation \(entry.operation)")
        }
        let operation = try binding(entry)
        guard operation.name == entry.operation else {
            throw OracleError(description: "the binding for \(entry.operation) builds \(operation.name)")
        }
        return operation
    }
}

// MARK: The reads, one table per operation

/// The reads of each operation's generated lens, written by hand against its
/// `Data`: one closure per path the manifest lists. A path no lens field
/// answers has no entry, and its row fails by name.
extension OracleOperation {
    static let fixtureReads: [String: @MainActor @Sendable (Fixture.Data) -> Manifest.Value] = [
        "characters.info.count": { $0.characters?.info?.count.manifestValue ?? .null },
        "characters.info.pages": { $0.characters?.info?.pages.manifestValue ?? .null },
        "characters.info.next": { $0.characters?.info?.next.manifestValue ?? .null },
        "characters.results.0.episode.0.characters.0.id": {
            $0.characters?.results?.element(0)?.episode.element(0)?.characters.element(0)?.id.manifestValue ?? .null
        },
        "characters.results.19.episode.0.characters.56.image": {
            $0.characters?.results?.element(19)?.episode.element(0)?.characters.element(56)?.image.manifestValue ?? .null
        },
    ]

    static let episodesReads: [String: @MainActor @Sendable (TestEpisodesQuery.Data) -> Manifest.Value] = [
        "character.episode.0.id": { $0.character?.episode.element(0)?.id.manifestValue ?? .null },
        "character.episode.0.name": { $0.character?.episode.element(0)?.name.manifestValue ?? .null },
    ]

    static let headerReads: [String: @MainActor @Sendable (TestHeaderQuery.Data) -> Manifest.Value] = [
        "character.name": { $0.character?.testHeader.name.manifestValue ?? .null },
        "character.status": { $0.character?.testHeader.status.manifestValue ?? .null },
        "character.species": { $0.character?.testHeader.species.manifestValue ?? .null },
        "character.origin.name": { $0.character?.testHeader.origin?.name.manifestValue ?? .null },
    ]

    /// `strict` is `@throwOnFieldError`: a field that throws reads as absent.
    static let profileReads: [String: @MainActor @Sendable (TestProfileQuery.Data) -> Manifest.Value] = [
        "character.name": { $0.character?.testProfile?.name.manifestValue ?? .null },
        "character.status": { $0.character?.testProfile?.status.manifestValue ?? .null },
        "character.origin.name": { $0.character?.testProfile?.origin.name.manifestValue ?? .null },
        "character.location.name": { (try? $0.character?.testProfile?.location.get())?.name.manifestValue ?? .null },
        "character.type": { (try? $0.character?.strict.type).manifestValue },
        "character.species": { (try? $0.character?.strict.species).manifestValue },
        "character.origin": { $0.character?.testProfile.map { _ in .object([:]) } ?? .null },
        "character.episode.1.air_date": { $0.character?.testAppearances?.episode.element(1)?.air_date.manifestValue ?? .null },
        "character.episode.0.name": { $0.character?.testAppearances?.episode.element(0)?.name.manifestValue ?? .null },
    ]

    static let strictReads: [String: @MainActor @Sendable (TestStrictQuery.Data) -> Manifest.Value] = [
        "character.name": { $0.character?.name.manifestValue ?? .null },
        "character.species": { $0.character?.species.manifestValue ?? .null },
    ]

    /// An element the list reads as absent is null; a present one is an
    /// object, whose fields have rows of their own.
    static let listReads: [String: @MainActor @Sendable (TestList.Data) -> Manifest.Value] = [
        "characters.results.0.name": { $0.characters?.results?.element(0)?.testRow.name.manifestValue ?? .null },
        "characters.results.1.name": { $0.characters?.results?.element(1)?.testRow.name.manifestValue ?? .null },
        "characters.results.2.name": { $0.characters?.results?.element(2)?.testRow.name.manifestValue ?? .null },
        "characters.results.1": { $0.characters?.results?.element(1).map { _ in Manifest.Value.object([:]) } ?? .null },
    ]

    static let notesReads: [String: @MainActor @Sendable (TestNotesQuery.Data) -> Manifest.Value] = [
        "character.id": { $0.character?.testNotes.id.manifestValue ?? .null },
        "character.name": { $0.character?.testNotes.name.manifestValue ?? .null },
        "character.notes.totalCount": { $0.character?.testNotes.notes.totalCount.manifestValue ?? .null },
        "character.notes.edges.0.node.id": { $0.character?.testNotes.notes.edges?.element(0)?.node?.id.manifestValue ?? .null },
        "character.notes.edges.1.node.text": { $0.character?.testNotes.notes.edges?.element(1)?.node?.text.manifestValue ?? .null },
        "character.notes.pageInfo.hasNextPage": { $0.character?.testNotes.notes.pageInfo.hasNextPage.manifestValue ?? .null },
    ]

    static let notesPaginationReads: [String: @MainActor @Sendable (TestNotesPaginationQuery.Data) -> Manifest.Value] = [
        "node.id": { $0.node?.testNotes?.id.manifestValue ?? .null },
        "node.name": { $0.node?.testNotes?.name.manifestValue ?? .null },
        "node.notes.totalCount": { $0.node?.testNotes?.notes.totalCount.manifestValue ?? .null },
        "node.notes.edges.0.node.id": { $0.node?.testNotes?.notes.edges?.element(0)?.node?.id.manifestValue ?? .null },
        "node.notes.edges.0.node.text": { $0.node?.testNotes?.notes.edges?.element(0)?.node?.text.manifestValue ?? .null },
        "node.notes.edges.0.cursor": { $0.node?.testNotes?.notes.edges?.element(0)?.cursor.manifestValue ?? .null },
        "node.notes.pageInfo.hasNextPage": { $0.node?.testNotes?.notes.pageInfo.hasNextPage.manifestValue ?? .null },
    ]

    static let authorNotesReads: [String: @MainActor @Sendable (TestAuthorNotesQuery.Data) -> Manifest.Value] = [
        "node.id": { $0.node?.note?.id.manifestValue ?? .null },
        "node.author.id": { $0.node?.note?.author?.id.manifestValue ?? .null },
        "node.author.name": { $0.node?.note?.author?.name.manifestValue ?? .null },
        "node.author.notes.edges.0.node.id": { $0.node?.note?.author?.notes.edges?.element(0)?.node?.id.manifestValue ?? .null },
        "node.author.notes.edges.0.node.text": { $0.node?.note?.author?.notes.edges?.element(0)?.node?.text.manifestValue ?? .null },
        "node.author.notes.edges.1.node.text": { $0.node?.note?.author?.notes.edges?.element(1)?.node?.text.manifestValue ?? .null },
    ]

    static let recentNotesReads: [String: @MainActor @Sendable (TestRecentNotesQuery.Data) -> Manifest.Value] = [
        "character.id": { $0.character?.testRecentNotes.id.manifestValue ?? .null },
        "character.notes.edges.0.node.id": { $0.character?.testRecentNotes.notes.edges?.element(0)?.node?.id.manifestValue ?? .null },
        "character.notes.edges.0.node.text": { $0.character?.testRecentNotes.notes.edges?.element(0)?.node?.text.manifestValue ?? .null },
        "character.notes.edges.0.cursor": { $0.character?.testRecentNotes.notes.edges?.element(0)?.cursor.manifestValue ?? .null },
        "character.notes.edges.1.node.text": { $0.character?.testRecentNotes.notes.edges?.element(1)?.node?.text.manifestValue ?? .null },
        "character.notes.edges.1.node.id": { $0.character?.testRecentNotes.notes.edges?.element(1)?.node?.id.manifestValue ?? .null },
    ]

    static let recentNotesPaginationReads: [String: @MainActor @Sendable (TestRecentNotesPaginationQuery.Data) -> Manifest.Value] = [
        "node.id": { $0.node?.testRecentNotes?.id.manifestValue ?? .null },
        "node.notes.edges.0.node.id": { $0.node?.testRecentNotes?.notes.edges?.element(0)?.node?.id.manifestValue ?? .null },
        "node.notes.edges.0.node.text": { $0.node?.testRecentNotes?.notes.edges?.element(0)?.node?.text.manifestValue ?? .null },
        "node.notes.edges.0.cursor": { $0.node?.testRecentNotes?.notes.edges?.element(0)?.cursor.manifestValue ?? .null },
        "node.notes.pageInfo.startCursor": { $0.node?.testRecentNotes?.notes.pageInfo.startCursor.manifestValue ?? .null },
    ]

    static let addNoteNodeReads: [String: @MainActor @Sendable (TestAddNoteNode.Data) -> Manifest.Value] = [
        "addNote.note.id": { $0.addNote?.note?.id.manifestValue ?? .null },
        "addNote.note.text": { $0.addNote?.note?.text.manifestValue ?? .null },
    ]

    static let addNoteNodeFirstReads: [String: @MainActor @Sendable (TestAddNoteNodeFirst.Data) -> Manifest.Value] = [
        "addNote.note.id": { $0.addNote?.note?.id.manifestValue ?? .null },
        "addNote.note.text": { $0.addNote?.note?.text.manifestValue ?? .null },
    ]

    /// `search` selects no field of its own, so each element reads as an
    /// empty object.
    static let keysReads: [String: @MainActor @Sendable (TestKeys.Data) -> Manifest.Value] = [
        "search": { $0.search.map { .list($0.map { _ in .object([:]) }) } ?? .null },
        "character.name": { $0.character?.name.manifestValue ?? .null },
        "charactersByIds.0.name": { $0.charactersByIds?.element(0)?.name.manifestValue ?? .null },
        "characters.info.count": { $0.characters?.info?.count.manifestValue ?? .null },
    ]

    static let assetsReads: [String: @MainActor @Sendable (TestAssetsQuery.Data) -> Manifest.Value] = [
        "assets.0.name": { $0.assets?.element(0)?.name.manifestValue ?? .null },
        "assets.0.size": { $0.assets?.element(0)?.size.manifestValue ?? .null },
        "assets.1.name": { $0.assets?.element(1)?.name.manifestValue ?? .null },
        "assets.1.size": { $0.assets?.element(1)?.size.manifestValue ?? .null },
    ]

    static let assetReads: [String: @MainActor @Sendable (TestAssetQuery.Data) -> Manifest.Value] = [
        "asset.owner.name": { $0.asset?.owner?.name.manifestValue ?? .null },
        "asset.uuid": { $0.asset?.uuid.manifestValue ?? .null },
        "asset.name": { $0.asset?.name.manifestValue ?? .null },
    ]

    /// Every mapped field of the three assets; a value the type cannot hold
    /// reads as null, and a list leaves such an element out.
    static let assetPricesReads: [String: @MainActor @Sendable (TestAssetPricesQuery.Data) -> Manifest.Value] = [
        "assets.0.price": { $0.assets?.element(0)?.price.manifestValue ?? .null },
        "assets.0.listedAt": { $0.assets?.element(0)?.listedAt.manifestValue ?? .null },
        "assets.0.page": { $0.assets?.element(0)?.page.manifestValue ?? .null },
        "assets.0.prices": { $0.assets?.element(0)?.prices.manifestValue ?? .null },
        "assets.1.price": { $0.assets?.element(1)?.price.manifestValue ?? .null },
        "assets.1.listedAt": { $0.assets?.element(1)?.listedAt.manifestValue ?? .null },
        "assets.1.page": { $0.assets?.element(1)?.page.manifestValue ?? .null },
        "assets.1.prices": { $0.assets?.element(1)?.prices.manifestValue ?? .null },
        "assets.2.price": { $0.assets?.element(2)?.price.manifestValue ?? .null },
        "assets.2.listedAt": { $0.assets?.element(2)?.listedAt.manifestValue ?? .null },
        "assets.2.page": { $0.assets?.element(2)?.page.manifestValue ?? .null },
        "assets.2.prices": { $0.assets?.element(2)?.prices.manifestValue ?? .null },
    ]

    static let assetPricesSpellings: [String: Spelling] = {
        var spellings: [String: Spelling] = [:]
        for index in 0..<3 {
            spellings["assets.\(index).price"] = spelled(as: Decimal.self)
            spellings["assets.\(index).listedAt"] = spelled(as: Date.self)
            spellings["assets.\(index).page"] = spelled(as: URL.self)
            spellings["assets.\(index).prices"] = spelled(as: Decimal.self)
        }
        return spellings
    }()

    /// A list of the schema enum `Status`, read with a value the schema does
    /// not declare as the `unknown` case with its text.
    static let setStatusesReads: [String: @MainActor @Sendable (TestSetStatuses.Data) -> Manifest.Value] = [
        "setLists.statuses": { $0.setLists?.statuses.manifestValue ?? .null }
    ]

    /// An enum's conversion cannot fail, so its text is written back as it
    /// was, a value the build does not know included.
    static let setStatusesSpellings: [String: Spelling] = [
        "setLists.statuses": spelled(as: Status.self)
    ]

    /// The manifest's text converted to `type` and written back as its
    /// `scalarText`, element by element in a list; a text the type cannot
    /// hold is left as it is, so the comparison shows it.
    static func spelled<T: MappedScalar>(as type: T.Type) -> Spelling {
        { value in respelled(value, as: type) }
    }

    private static func respelled<T: MappedScalar>(_ value: Manifest.Value, as type: T.Type) -> Manifest.Value {
        switch value {
        case .string(let text): T(scalarText: text).map { .string($0.scalarText) } ?? value
        case .list(let items): .list(items.map { respelled($0, as: type) })
        default: value
        }
    }

    /// A character's server fields and its two client fields, which read as
    /// nil until a payload committed by hand writes them.
    static let pinnedCharacterReads: [String: @MainActor @Sendable (TestPinnedCharacter.Data) -> Manifest.Value] = [
        "character.id": { $0.character?.id.manifestValue ?? .null },
        "character.name": { $0.character?.name.manifestValue ?? .null },
        "character.status": { $0.character?.status.manifestValue ?? .null },
        "character.isPinned": { $0.character?.isPinned.manifestValue ?? .null },
        "character.note": { $0.character?.note.manifestValue ?? .null },
    ]

    /// The client-only list of drafts, one linking a server character, and
    /// that character read beside it.
    static let draftsReads: [String: @MainActor @Sendable (TestDrafts.Data) -> Manifest.Value] = [
        "drafts.0.id": { $0.drafts?.element(0)?.id.manifestValue ?? .null },
        "drafts.0.text": { $0.drafts?.element(0)?.text.manifestValue ?? .null },
        "drafts.0.about.id": { $0.drafts?.element(0)?.about?.id.manifestValue ?? .null },
        "drafts.0.about.name": { $0.drafts?.element(0)?.about?.name.manifestValue ?? .null },
        "drafts.1.id": { $0.drafts?.element(1)?.id.manifestValue ?? .null },
        "drafts.1.text": { $0.drafts?.element(1)?.text.manifestValue ?? .null },
        "drafts.1.about": { $0.drafts?.element(1)?.about.map { _ in .object([:]) } ?? .null },
        "character.id": { $0.character?.id.manifestValue ?? .null },
        "character.name": { $0.character?.name.manifestValue ?? .null },
    ]

    /// The transient root field's records beside a character; memory reads
    /// them as any records, whatever the image keeps.
    static let secretsReads: [String: @MainActor @Sendable (TestSecrets.Data) -> Manifest.Value] = [
        "secrets.0.id": { $0.secrets?.element(0)?.id.manifestValue ?? .null },
        "secrets.0.body": { $0.secrets?.element(0)?.body.manifestValue ?? .null },
        "secrets.1.id": { $0.secrets?.element(1)?.id.manifestValue ?? .null },
        "secrets.1.body": { $0.secrets?.element(1)?.body.manifestValue ?? .null },
        "character.id": { $0.character?.id.manifestValue ?? .null },
        "character.name": { $0.character?.name.manifestValue ?? .null },
    ]

    /// A character and the record of a transient type it links.
    static let characterSecretReads: [String: @MainActor @Sendable (TestCharacterSecret.Data) -> Manifest.Value] = [
        "character.id": { $0.character?.id.manifestValue ?? .null },
        "character.name": { $0.character?.name.manifestValue ?? .null },
        "character.secret.id": { $0.character?.secret?.id.manifestValue ?? .null },
        "character.secret.body": { $0.character?.secret?.body.manifestValue ?? .null },
    ]

    static let quotesReads: [String: @MainActor @Sendable (TestQuotesQuery.Data) -> Manifest.Value] = [
        "quotes.0.rate": { $0.quotes?.element(0)?.rate.manifestValue ?? .null },
        "quotes.1.rate": { $0.quotes?.element(1)?.rate.manifestValue ?? .null },
        "quotes.2.rate": { $0.quotes?.element(2)?.rate.manifestValue ?? .null },
    ]

    static let quoteReads: [String: @MainActor @Sendable (TestQuoteQuery.Data) -> Manifest.Value] = [
        "quote.base": { $0.quote?.base.manifestValue ?? .null },
        "quote.quote": { $0.quote?.quote.manifestValue ?? .null },
        "quote.rate": { $0.quote?.rate.manifestValue ?? .null },
    ]

    static let conditionsReads: [String: @MainActor @Sendable (TestConditions.Data) -> Manifest.Value] = [
        "character.name": { $0.character?.name.manifestValue ?? .null },
        "character.origin.id": { $0.character?.origin?.id.manifestValue ?? .null },
        "character.status": { $0.character?.status.manifestValue ?? .null },
        "character.origin.name": { $0.character?.origin?.name.manifestValue ?? .null },
        "character.origin.dimension": { $0.character?.origin?.dimension.manifestValue ?? .null },
    ]

    /// `label` is an alias on two type conditions: the element's own type
    /// picks the one that answers.
    static let unionReads: [String: @MainActor @Sendable (TestUnion.Data) -> Manifest.Value] = [
        "search.0.label": { label($0.search?.element(0)) },
        "search.1.label": { label($0.search?.element(1)) },
        "search.0.status": { $0.search?.element(0)?.asCharacter?.status.manifestValue ?? .null },
        "search.0.type": { $0.search?.element(0)?.asLocation?.type.manifestValue ?? .null },
        "search.0.name": { $0.search?.element(0)?.asNamed?.name.manifestValue ?? .null },
        "search.1.status": { $0.search?.element(1)?.asCharacter?.status.manifestValue ?? .null },
        "search.1.name": { $0.search?.element(1)?.asNamed?.name.manifestValue ?? .null },
        "search.2.air_date": { $0.search?.element(2)?.asEpisode?.air_date.manifestValue ?? .null },
    ]

    @MainActor private static func label(_ element: TestUnion.Data.Search?) -> Manifest.Value {
        if let character = element?.asCharacter { return character.label.manifestValue }
        if let location = element?.asLocation { return location.label.manifestValue }
        return .null
    }

    static let nodeFieldsReads: [String: @MainActor @Sendable (TestNodeFields.Data) -> Manifest.Value] = [
        "node.id": { $0.node?.id.manifestValue ?? .null },
        "node.name": { $0.node?.asCharacter?.name.manifestValue ?? .null },
    ]

    /// The deferred fragment sits under an abstract selection; it reads
    /// through the record's own type.
    static let nodeDeferredReads: [String: @MainActor @Sendable (TestNodeDeferred.Data) -> Manifest.Value] = [
        "node.id": { $0.node?.id.manifestValue ?? .null },
        "node.name": { $0.node?.asCharacter?.name.manifestValue ?? .null },
        "node.episode.0.name": { $0.node?.appearances?.testAppearances?.episode.element(0)?.name.manifestValue ?? .null },
        "node.episode.1.air_date": { $0.node?.appearances?.testAppearances?.episode.element(1)?.air_date.manifestValue ?? .null },
    ]

    static let twoSpreadsReads: [String: @MainActor @Sendable (TestTwoSpreads.Data) -> Manifest.Value] = [
        "character.name": { $0.character?.testRow.name.manifestValue ?? .null },
        "character.status": { $0.character?.testRow.status.manifestValue ?? .null },
        "character.image": { $0.character?.again?.image.manifestValue ?? .null },
    ]

    static let deleteNoteReads: [String: @MainActor @Sendable (TestDeleteNote.Data) -> Manifest.Value] = [
        "removeNote.removedNoteId": { $0.removeNote?.removedNoteId.manifestValue ?? .null },
    ]

    static let addNoteReads: [String: @MainActor @Sendable (TestAddNote.Data) -> Manifest.Value] = [
        "addNote.noteEdge.cursor": { $0.addNote?.noteEdge?.cursor.manifestValue ?? .null },
        "addNote.noteEdge.node.id": { $0.addNote?.noteEdge?.node?.id.manifestValue ?? .null },
        "addNote.noteEdge.node.text": { $0.addNote?.noteEdge?.node?.text.manifestValue ?? .null },
    ]

    static let addNoteFirstReads: [String: @MainActor @Sendable (TestAddNoteFirst.Data) -> Manifest.Value] = [
        "addNote.noteEdge.cursor": { $0.addNote?.noteEdge?.cursor.manifestValue ?? .null },
        "addNote.noteEdge.node.id": { $0.addNote?.noteEdge?.node?.id.manifestValue ?? .null },
        "addNote.noteEdge.node.text": { $0.addNote?.noteEdge?.node?.text.manifestValue ?? .null },
    ]

    static let searchReads: [String: @MainActor @Sendable (TestSearch.Data) -> Manifest.Value] = [
        "search.0.id": { searchID($0.search?.element(0)) },
        "search.1.id": { searchID($0.search?.element(1)) },
        "search.0.name": { searchName($0.search?.element(0)) },
        "search.2.name": { searchName($0.search?.element(2)) },
        "search.1.dimension": { $0.search?.element(1)?.asLocation?.dimension.manifestValue ?? .null },
    ]

    @MainActor private static func searchID(_ element: TestSearch.Data.Search?) -> Manifest.Value {
        if let character = element?.asCharacter { return character.id.manifestValue }
        if let location = element?.asLocation { return location.id.manifestValue }
        return .null
    }

    @MainActor private static func searchName(_ element: TestSearch.Data.Search?) -> Manifest.Value {
        if let character = element?.asCharacter { return character.name.manifestValue }
        if let location = element?.asLocation { return location.name.manifestValue }
        return .null
    }

    static let searchOriginsReads: [String: @MainActor @Sendable (TestSearchOrigins.Data) -> Manifest.Value] = [
        "search.0.origin.name": { $0.search?.element(0)?.asCharacter?.origin?.name.manifestValue ?? .null },
        "search.1.origin": { $0.search?.element(1)?.asCharacter?.origin.map { _ in .object([:]) } ?? .null },
    ]

    static let setFavoriteReads: [String: @MainActor @Sendable (TestSetFavorite.Data) -> Manifest.Value] = [
        "setFavorite.character.id": { $0.setFavorite?.character?.id.manifestValue ?? .null },
        "setFavorite.character.name": { $0.setFavorite?.character?.name.manifestValue ?? .null },
        "setFavorite.character.favorite": { $0.setFavorite?.character?.favorite.manifestValue ?? .null },
    ]

    static let renameReads: [String: @MainActor @Sendable (TestRename.Data) -> Manifest.Value] = [
        "rename.character.id": { $0.rename?.character?.id.manifestValue ?? .null },
        "rename.character.name": { $0.rename?.character?.name.manifestValue ?? .null },
    ]

    static let removeNoteReads: [String: @MainActor @Sendable (TestRemoveNote.Data) -> Manifest.Value] = [
        "removeNote.removedNoteId": { $0.removeNote?.removedNoteId.manifestValue ?? .null },
        "removeNote.deleted": { $0.removeNote?.deleted.manifestValue ?? .null },
    ]

    static let noteAddedReads: [String: @MainActor @Sendable (TestNoteAdded.Data) -> Manifest.Value] = [
        "noteAdded.noteEdge.cursor": { $0.noteAdded?.noteEdge?.cursor.manifestValue ?? .null },
        "noteAdded.noteEdge.node.id": { $0.noteAdded?.noteEdge?.node?.id.manifestValue ?? .null },
        "noteAdded.noteEdge.node.text": { $0.noteAdded?.noteEdge?.node?.text.manifestValue ?? .null },
    ]

    static let tokenizerReads: [String: @MainActor @Sendable (TestTokenizerQuery.Data) -> Manifest.Value] = [
        "tokenizer.id": { $0.tokenizer?.id.manifestValue ?? .null },
        "tokenizer.text": { $0.tokenizer?.text.manifestValue ?? .null },
        "tokenizer.strings": { $0.tokenizer?.strings.manifestValue ?? .null },
        "tokenizer.flags": { $0.tokenizer?.flags.manifestValue ?? .null },
        "tokenizer.jsons.6": { $0.tokenizer?.jsons?.element(6).manifestValue ?? .null },
    ]
}

// MARK: Lifting what a lens reads into the manifest's values

/// A value a lens reads, in the manifest's spelling.
protocol ManifestValueConvertible {
    var manifestValue: Manifest.Value { get }
}

extension String: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .string(self) }
}

extension Int: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .int(self) }
}

extension Double: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .double(self) }
}

extension Bool: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .bool(self) }
}

/// A mapped scalar is read in the manifest's spelling as its text.
extension Decimal: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .string(scalarText) }
}

extension Date: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .string(scalarText) }
}

extension URL: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .string(scalarText) }
}

/// A generated enum is read in the manifest's spelling as its text, so
/// `unknown("GHOST")` is the response's `GHOST`.
extension Status: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .string(scalarText) }
}

extension Optional: ManifestValueConvertible where Wrapped: ManifestValueConvertible {
    var manifestValue: Manifest.Value { map(\.manifestValue) ?? .null }
}

extension Array: ManifestValueConvertible where Element: ManifestValueConvertible {
    var manifestValue: Manifest.Value { .list(map(\.manifestValue)) }
}

extension RandomAccessCollection where Index == Int {
    /// The element at `index`, or nil past the end.
    func element(_ index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: Reading a case's variables

extension Manifest.Case {
    private func variable(_ name: String) throws -> Manifest.Value? {
        guard let value = variables[name], value != .null else { return nil }
        return value
    }

    private func required(_ name: String) throws -> Manifest.Value {
        guard let value = try variable(name) else {
            throw OracleError(description: "\(self.name): the variable \(name) is missing")
        }
        return value
    }

    private func mismatch(_ name: String, _ value: Manifest.Value) -> OracleError {
        OracleError(description: "\(self.name): the variable \(name) is \(value), of the wrong type")
    }

    func string(_ name: String) throws -> String {
        let value = try required(name)
        guard case .string(let string) = value else { throw mismatch(name, value) }
        return string
    }

    func optionalString(_ name: String) throws -> String? {
        guard try variable(name) != nil else { return nil }
        return try string(name)
    }

    func optionalInt(_ name: String) throws -> Int? {
        guard let value = try variable(name) else { return nil }
        guard case .int(let int) = value else { throw mismatch(name, value) }
        return int
    }

    func bool(_ name: String) throws -> Bool {
        let value = try required(name)
        guard case .bool(let bool) = value else { throw mismatch(name, value) }
        return bool
    }

    func strings(_ name: String) throws -> [String] {
        let value = try required(name)
        guard case .list(let items) = value else { throw mismatch(name, value) }
        return try items.map { item in
            guard case .string(let string) = item else { throw mismatch(name, value) }
            return string
        }
    }
}
