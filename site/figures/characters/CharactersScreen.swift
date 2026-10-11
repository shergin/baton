import Baton
import SwiftUI

struct CharacterRow: View {
    @Fragment("""
    fragment CharacterRow_character on Character {
      name
      status
      species
      image
    }
    """)
    var character: CharacterRow_character

    var body: some View {
        HStack {
            Avatar(url: character.image)
            VStack(alignment: .leading) {
                Text(character.name ?? "Unknown")
                Text("\(character.status ?? "?") · \(character.species ?? "?")")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CharactersScreen: View {
    @Query("""
    query CharactersQuery($page: Int) {
      characters(page: $page) {
        results { id ...CharacterRow_character }
      }
    }
    """)
    var characters: CharactersQuery

    var body: some View {
        switch characters.phase {
        case .ready(let data):
            List {
                ForEach(data.characters?.results ?? .empty) { character in
                    CharacterRow(character: character.characterRow)
                }
            }
            .navigationTitle("Characters")
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorView(error) { characters.retry() }
        }
    }
}
