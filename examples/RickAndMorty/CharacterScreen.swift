import Baton
import SwiftUI

/// The header a detail shows at once. The list prefetched these fields, so the
/// handle resolves as ready before the first body runs.
struct CharacterHeader: View {
    @Fragment("""
        fragment CharacterHeader_character on Character {
          name
          status
          species
          gender
          image
          origin { id name }
          location { id name }
        }
        """)
    var character: CharacterHeader_character

    var body: some View {
        VStack(spacing: 12) {
            Avatar(url: character.image, size: 160)
            Text(character.name ?? "Unknown").font(.largeTitle.bold())
            Text([character.status, character.species, character.gender].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                if let origin = character.origin {
                    Place(label: "Origin", name: origin.name, id: origin.id)
                }
                if let location = character.location {
                    Place(label: "Last seen", name: location.name, id: location.id)
                }
            }
        }
        .padding()
    }

    struct Place: View {
        let label: String
        let name: String?
        let id: String?

        var body: some View {
            VStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if let id, !id.isEmpty {
                    NavigationLink(name ?? "Unknown", value: LocationQuery(id: id))
                } else {
                    Text(name ?? "Unknown")
                }
            }
        }
    }
}

/// Two operations: the header, usually satisfied from the store, and the
/// episodes, which only the detail needs. `@defer` unifies them in a later release.
struct CharacterScreen: View {
    @Query("""
        query CharacterHeaderQuery($id: ID!) {
          character(id: $id) { ...CharacterHeader_character }
        }
        """)
    var header: CharacterHeaderQuery

    @Query("""
        query CharacterEpisodesQuery($id: ID!) {
          character(id: $id) {
            episode { id name episode air_date }
          }
        }
        """)
    var episodes: CharacterEpisodesQuery

    init(header: CharacterHeaderQuery) {
        self.header = header
        episodes = CharacterEpisodesQuery(id: header.id)
    }

    var body: some View {
        List {
            PhaseView(phase: header.phase, retry: header.retry) { data in
                if let character = data.character {
                    CharacterHeader(character: character.characterHeader)
                }
            }
            Section("Episodes") {
                switch episodes.phase {
                case .ready(let data):
                    if let character = data.character {
                        ForEach(character.episode) { episode in
                            NavigationLink(value: EpisodeQuery(id: episode.id ?? "")) {
                                VStack(alignment: .leading) {
                                    Text(episode.name ?? "Unknown")
                                    Text([episode.episode, episode.air_date].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                case .loading:
                    ProgressView()
                case .failed(let error):
                    Text(String(describing: error)).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Character")
    }
}
