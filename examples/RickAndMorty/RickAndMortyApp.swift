import Baton
import SwiftUI

/// The sample: the public Rick and Morty API through Baton. Characters, their
/// details, episodes and locations share one store, so a character seen in a
/// list, in an episode's cast and among a location's residents is one record.
@main
struct RickAndMortyApp: App {
    @State private var environment = Baton.Environment(url: URL(string: "https://rickandmortyapi.com/graphql")!)

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CharactersScreen(characters: .init(page: 1))
                    .navigationDestination(for: CharacterHeaderQuery.self) { CharacterScreen(header: $0) }
                    .navigationDestination(for: EpisodeQuery.self) { EpisodeScreen(episode: $0) }
                    .navigationDestination(for: LocationQuery.self) { LocationScreen(location: $0) }
            }
            .environment(\.baton, environment)
            .frame(minWidth: 480, minHeight: 640)
        }
    }
}

/// Loading, failure and empty states, the same everywhere.
struct PhaseView<Data, Content: View>: View {
    let phase: Phase<Data>
    let retry: () -> Void
    @ViewBuilder let content: (Data) -> Content

    var body: some View {
        switch phase {
        case .ready(let data):
            content(data)
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label("Could not load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(String(describing: error))
            } actions: {
                Button("Retry", action: retry)
            }
        }
    }
}
