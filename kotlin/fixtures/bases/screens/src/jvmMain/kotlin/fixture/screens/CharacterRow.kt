package fixture.screens

import baton.Fragment
import baton.Query
import fixture.shared.characterStatus

/**
 * What the dependent module shows of a character: its name, and the base's
 * status over the spread's lens, with the base's argument bound.
 */
@Fragment(
    """
    fragment CharacterRow_character on Character {
      name
      ...CharacterStatus_character @arguments(full: true)
    }
    """,
)
fun characterRow(character: CharacterRow_character): String =
    listOfNotNull(character.name, characterStatus(character.characterStatus)).joinToString(": ")

/** The screen's operation, whose response the row's lens and, through the spread, the base's lens read. */
@Query(
    $$"""
    query CharacterScreenQuery($id: ID!) {
      character(id: $id) { ...CharacterRow_character }
    }
    """,
)
fun characterScreen(query: CharacterScreenQuery): String = query.id
