import Baton
import Shared

/// A view of the dependent module that spreads the base's fragment with an
/// argument and hands the spread's lens to the base's view.
public struct CharacterRow {
    @Fragment("""
        fragment CharacterRow_character on Character {
          name
          ...CharacterStatus_character @arguments(full: true)
        }
        """)
    public var character: CharacterRow_character

    public init(character: CharacterRow_character) {
        self.character = character
    }

    @MainActor public var status: CharacterStatus {
        CharacterStatus(character: character.characterStatus)
    }
}

/// The screen's operation, whose response the row's lens and, through the
/// spread, the base's lens read.
@MainActor
struct CharacterScreen {
    @Query("""
        query CharacterScreenQuery($id: ID!) {
          character(id: $id) {
            ...CharacterRow_character
          }
        }
        """)
    var query: CharacterScreenQuery
}
