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

struct CharacterScreen: View {
    @Query("""
    query CharacterQuery($id: ID!) @cacheExpiration(seconds: 300) {
      character(id: $id) { ...CharacterHeader_character }
    }
    """)
    var character: CharacterQuery

    var body: some View {
        switch character.phase {
        case .ready(let data):
            if let character = data.character {
                CharacterHeader(character: character.characterHeader)
            }
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { character.retry() }
        }
    }
}
