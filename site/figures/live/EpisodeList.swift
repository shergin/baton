import Baton
import SwiftUI

struct EpisodeList: View {
    @Query("""
    query EpisodesQuery($id: ID!) {
      character(id: $id) {
        name
        episode @stream(label: "episodes", initialCount: 3) { id name }
      }
    }
    """)
    var episodes: EpisodesQuery

    var body: some View {
        if case .ready(let data) = episodes.phase, let character = data.character {
            List {
                ForEach(character.episode) { episode in
                    Text(episode.name ?? "Untitled")
                }
                if episodes.isRefreshing {
                    ProgressView()
                }
            }
        }
    }
}
