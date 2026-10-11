import Baton
import SwiftUI

struct CharacterHeader: View {
    @Fragment("""
    fragment CharacterHeader_character on Character {
      name
      status
      species
      image
      origin { name }
    }
    """)
    var character: CharacterHeader_character

    var body: some View {
        VStack {
            Avatar(url: character.image)
            Text(character.name ?? "Unknown").font(.largeTitle)
            Text("\(character.status ?? "?") · \(character.species ?? "?")")
            if let origin = character.origin {
                Text("From \(origin.name ?? "somewhere")")
            }
        }
    }
}
