import Baton
import BatonSpec
import BatonTesting
import Foundation

/// The recorded response for `Fixture(page: 1)`.
let fixtureData = Spec.data("rickandmorty/characters-page-1.json")

/// A response or a part under `spec/tests/`, by file name.
func fixture(_ name: String) -> Data {
    Spec.data("tests/\(name).json")
}

/// A recorded page of the notes connection.
func notesPage(_ number: Int) -> Data {
    fixture("notes-page-\(number)")
}

/// A transport that answers the notes query with the first page and the
/// pagination query with the page after the cursor it carries.
func notesTransport() -> RecordedTransport {
    RecordedTransport { request in
        if request.operationName == TestNotesQuery.name { return notesPage(1) }
        switch request.variables["cursor"] {
        case .string("c2")?: return notesPage(2)
        case .string("c4")?: return notesPage(3)
        default: return notesPage(1)
        }
    }
}

extension Ingest {
    /// Normalizes a response at the query root, where the tests read query
    /// responses unless they say otherwise.
    static func normalize(_ data: Data, plan: ResolvedSelection) throws -> ChangeSet {
        try normalize(data, plan: plan, rootKey: Store.rootKey)
    }
}
