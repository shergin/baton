import Baton
import SwiftUI

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
