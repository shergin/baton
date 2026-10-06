import Baton
import Exchange
import SwiftUI

/// The sample on GitHub's API: what the viewer has to look at (open issues
/// and pull requests assigned to or created by them), a repository with a
/// star toggle, and an issue with its comments and reactions. Reads, writes
/// with optimistic responses, interfaces and unions, and a lookup by id,
/// against a schema of about 1,800 definitions. Needs a token:
///
///     GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage
@main
struct GitHubTriageApp: App {
    private nonisolated static let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ""

    /// The exchange of `docs/recipes/exchange.md` over GitHub's endpoint: a
    /// query the API refused with a 5xx or lost the connection of is sent
    /// again, under a deadline; a mutation never is. A personal access token
    /// is not renewed, so a 401 is sent once more with the same token. The
    /// store keeps an image on disk, so a launch renders before the network
    /// answers.
    @State private var environment = GitHubTriageApp.makeEnvironment()

    private static func makeEnvironment() -> Baton.Environment {
        Baton.Environment(
            transport: Exchange(base: URLSessionTransport(
                url: URL(string: "https://api.github.com/graphql")!,
                credentials: { ["Authorization": "Bearer \(token)"] }
            )),
            store: Store(persistence: Persistence(name: "GitHubTriage", version: Types.schemaDigest))
        )
    }

    /// The sign-out the README describes: the environment ends, which cancels
    /// what it started and closes the image; the image's file is removed; and
    /// a new environment makes its own. The token stays, so this is a start
    /// over, as a sign-out followed by a sign-in is.
    private func signOut() async {
        let ending = environment
        await ending.end()
        ending.store.persistence?.removeAll()
        environment = Self.makeEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            if Self.token.isEmpty {
                ContentUnavailableView(
                    "Set GITHUB_TOKEN",
                    systemImage: "key",
                    description: Text("A personal access token with the repo scope, for example `GITHUB_TOKEN=$(gh auth token) swift run GitHubTriage`.")
                )
                .frame(minWidth: 480, minHeight: 320)
            } else {
                NavigationStack {
                    TriageScreen(triage: .init())
                        .navigationDestination(for: IssueQuery.self) { IssueScreen(issue: $0) }
                        .navigationDestination(for: RepositoryQuery.self) { RepositoryScreen(repository: $0) }
                        .toolbar {
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                                Task { await signOut() }
                            }
                        }
                }
                .environment(\.baton, environment)
                .id(ObjectIdentifier(environment))
                .frame(minWidth: 600, minHeight: 760)
            }
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

/// An ISO 8601 timestamp from the API, shown as a date.
func shortDate(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .omitted)
}
