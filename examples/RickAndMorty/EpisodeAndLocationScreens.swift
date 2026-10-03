import Baton
import SwiftUI

struct EpisodeScreen: View {
    @Query("""
        query EpisodeQuery($id: ID!) {
          episode(id: $id) {
            name
            episode
            air_date
            characters { id ...CharacterRow_character ...CharacterHeader_character }
          }
        }
        """)
    var episode: EpisodeQuery

    var body: some View {
        PhaseView(phase: episode.phase, retry: episode.retry) { data in
            List {
                if let episode = data.episode {
                    Section {
                        Text(episode.name ?? "Unknown").font(.title2.bold())
                        Text([episode.episode, episode.air_date].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    Section("Cast") {
                        ForEach(episode.characters) { character in
                            NavigationLink(value: CharacterHeaderQuery(id: character.id ?? "")) {
                                CharacterRow(character: character.characterRow)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Episode")
    }
}

struct LocationScreen: View {
    @Query("""
        query LocationQuery($id: ID!) {
          location(id: $id) {
            name
            type
            dimension
            residents { id ...CharacterRow_character ...CharacterHeader_character }
          }
        }
        """)
    var location: LocationQuery

    var body: some View {
        PhaseView(phase: location.phase, retry: location.retry) { data in
            List {
                if let location = data.location {
                    Section {
                        Text(location.name ?? "Unknown").font(.title2.bold())
                        Text([location.type, location.dimension].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    Section("Residents") {
                        ForEach(location.residents) { character in
                            NavigationLink(value: CharacterHeaderQuery(id: character.id ?? "")) {
                                CharacterRow(character: character.characterRow)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Location")
    }
}
