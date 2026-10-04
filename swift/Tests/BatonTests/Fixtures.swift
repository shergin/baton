import BatonSpec
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
