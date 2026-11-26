package fixture.shared

import baton.Fragment

/**
 * What the base module shows of a character, read through its lens alone.
 * The fragment takes an argument, so a spread that binds it proves the bound
 * value reaches this module's lens.
 */
@Fragment(
    $$"""
    fragment CharacterStatus_character on Character @argumentDefinitions(full: {type: "Boolean", defaultValue: false}) {
      status
      species
      origin @include(if: $full) { name }
    }
    """,
)
fun characterStatus(character: CharacterStatus_character): String =
    listOfNotNull(character.status, character.species, character.origin?.name).joinToString(", ")
