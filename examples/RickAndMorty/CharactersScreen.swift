import Baton
import SwiftUI

/// A row declares exactly what it reads.
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
        HStack(spacing: 12) {
            Avatar(url: character.image, size: 44)
            VStack(alignment: .leading) {
                Text(character.name ?? "Unknown").font(.headline)
                Text([character.status, character.species].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The list. It also spreads the detail header's fragment, so tapping a row
/// opens a detail whose first body renders from the store.
struct CharactersScreen: View {
    @Query("""
        query CharactersScreenQuery($page: Int) {
          characters(page: $page) {
            info { count pages }
            results {
              id
              ...CharacterRow_character
              ...CharacterHeader_character
            }
          }
        }
        """)
    var characters: CharactersScreenQuery

    var body: some View {
        PhaseView(phase: characters.phase, retry: characters.retry) { data in
            List {
                if let results = data.characters?.results {
                    ForEach(results) { character in
                        NavigationLink(value: CharacterHeaderQuery(id: character.id ?? "")) {
                            CharacterRow(character: character.characterRow)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if characters.isRefreshing { ProgressView().padding() }
            }
        }
        .navigationTitle("Characters")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await characters.refetch() }
            }
        }
    }
}

struct Avatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.secondary.opacity(0.2)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5))
    }
}
