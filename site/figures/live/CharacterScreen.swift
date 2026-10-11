import Baton
import SwiftUI

struct CharacterScreen: View {
    @Query("""
    query CharacterQuery($id: ID!) {
      character(id: $id) {
        name
        ...CharacterNotes_character @defer
      }
    }
    """)
    var character: CharacterQuery

    var body: some View {
        if case .ready(let data) = character.phase, let character = data.character {
            Text(character.name ?? "Unknown").font(.largeTitle)
            if let notes = character.characterNotes {
                CharacterNotes(character: notes)
            } else {
                ProgressView()
            }
        }
    }
}
