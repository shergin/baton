import Baton
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
    private static let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ""

    @State private var environment = Baton.Environment(
        url: URL(string: "https://api.github.com/graphql")!,
        headers: ["Authorization": "Bearer \(token)"]
    )

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
                }
                .environment(\.baton, environment)
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
