import Baton

/// A view of the base module that other modules embed: its fragment takes an
/// argument, so a spread that binds it proves the bound value reaches this
/// module's lens.
public struct CharacterStatus {
    @Fragment("""
        fragment CharacterStatus_character on Character @argumentDefinitions(full: {type: "Boolean", defaultValue: false}) {
          status
          species
          origin @include(if: $full) { name }
        }
        """)
    public var character: CharacterStatus_character

    public init(character: CharacterStatus_character) {
        self.character = character
    }

    /// What the view shows, read through the lens alone.
    @MainActor public var summary: String {
        [character.status, character.species, character.origin?.name].compactMap(\.self).joined(separator: ", ")
    }
}
