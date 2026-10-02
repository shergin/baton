import Baton

/// A row declares exactly what it reads.
struct CharacterRow {
    @Fragment("""
        fragment CharacterRow_character on Character {
          name
          status
          image
          origin { name }
        }
        """)
    var character: CharacterRow_character
}

/// The screen spreads the row's fragment; the compiler emits one operation.
struct CharactersScreen {
    @Query("""
        query CharactersScreenQuery($page: Int) {
          characters(page: $page) {
            info { next pages }
            results { id ...CharacterRow_character }
          }
        }
        """)
    var characters: CharactersScreenQuery
}

/// Deliberately wrong on purpose: the property type does not match the fragment,
/// which the compiler reports as a warning at the GraphQL text.
struct Oops {
    @Fragment("fragment Oops_thing on Character { id name }") var thing: CharacterRow_character
}
