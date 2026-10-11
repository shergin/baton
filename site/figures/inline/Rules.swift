import Baton
import SwiftUI

struct Rules {
    @Fragment("""
    fragment CharacterValue_character on Character @inline {
      id
      name
      status
      episode { id }
    }
    """)
    var character: CharacterValue_character
}

func isSeriesRegular(_ character: CharacterValue_character) -> Bool {
    character.status == "Alive" && character.episode.count > 10
}

struct CharacterScreen: View {
    @Query("""
    query CharacterQuery($id: ID!) {
      character(id: $id) {
        name
        ...CharacterValue_character
      }
    }
    """)
    var character: CharacterQuery

    var body: some View {
        if case .ready(let data) = character.phase, let character = data.character {
            // The spread's accessor builds the value from the record, now.
            let value = character.characterValue
            Text(character.name ?? "Unknown")
            if isSeriesRegular(value) { Text("A series regular") }
            Button("Share") { share(value) }
        }
    }
}
