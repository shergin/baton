import Baton
import SwiftUI

/// An issue row declares exactly what it reads; `author` is an interface
/// (`Actor`), read through the record's concrete type. The row requires an
/// author: an issue whose author is gone reads as no row, and the environment
/// logs where, as Relay's `@required(action: LOG)` does.
struct IssueRow: View {
    @Fragment("""
        fragment IssueRow_issue on Issue {
          number
          title
          state
          repository { nameWithOwner }
          author @required(action: LOG) { login }
        }
        """)
    var issue: IssueRow_issue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue.title).font(.headline)
            Text("\(issue.repository.nameWithOwner) #\(issue.number) · \(issue.author.login) · \(issue.state.word)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The schema's `IssueState` is generated as a Swift enum, so a row
/// switches over its cases; a state this build does not know shows its text.
extension IssueState {
    var word: String {
        switch self {
        case .OPEN: "open"
        case .CLOSED: "closed"
        case .unknown(let text): text.lowercased()
        }
    }
}

struct PullRequestRow: View {
    @Fragment("""
        fragment PullRequestRow_pullRequest on PullRequest {
          number
          title
          isDraft
          repository { nameWithOwner }
          author { login }
        }
        """)
    var pullRequest: PullRequestRow_pullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "arrow.triangle.pull")
                Text(pullRequest.title).font(.headline)
                if pullRequest.isDraft { Text("Draft").font(.caption).padding(3).background(.quaternary, in: Capsule()) }
            }
            Text("\(pullRequest.repository.nameWithOwner) #\(pullRequest.number) · \(pullRequest.author?.login ?? "ghost")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// Two searches, aliased, over the `SearchResultItem` union. The compiler
/// adds `__typename` to every abstract selection; the ingest keys each node
/// by its concrete type, so an issue seen here is the same record the issue
/// screen reads. Relay requires `@alias` on a spread inside an inline
/// fragment on a union, and so does Baton: the spread is then reachable only
/// through the optional `asIssue`.
struct TriageScreen: View {
    @Query("""
        query TriageQuery {
          viewer { login }
          assigned: search(query: "is:open assignee:@me", type: ISSUE, first: 30) {
            issueCount
            nodes {
              ... on Issue { id ...IssueRow_issue @alias }
              ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
            }
          }
          created: search(query: "is:open author:@me", type: ISSUE, first: 30) {
            issueCount
            nodes {
              ... on Issue { id ...IssueRow_issue @alias }
              ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
            }
          }
        }
        """)
    var triage: TriageQuery
    @SwiftUI.Environment(\.baton) private var environment

    var body: some View {
        PhaseView(phase: triage.phase, retry: triage.retry) { data in
            List {
                Section("Assigned to \(data.viewer.login) · \(data.assigned.issueCount)") {
                    if let nodes = data.assigned.nodes {
                        ForEach(nodes) { node in
                            TriageRow(issue: node.asIssue.flatMap { issue in issue.issueRow.map { (issue.id, $0) } }, pullRequest: node.asPullRequest?.pullRequestRow)
                        }
                    }
                }
                Section("Created by \(data.viewer.login) · \(data.created.issueCount)") {
                    if let nodes = data.created.nodes {
                        ForEach(nodes) { node in
                            TriageRow(issue: node.asIssue.flatMap { issue in issue.issueRow.map { (issue.id, $0) } }, pullRequest: node.asPullRequest?.pullRequestRow)
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if triage.isRefreshing { ProgressView().padding() }
            }
        }
        .navigationTitle("Triage")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { try? await triage.refetch() }
            }
            Button("Refresh rows", systemImage: "arrow.triangle.2.circlepath") {
                guard case .ready(let data) = triage.phase, let environment else { return }
                let ids = (data.assigned.nodes ?? .empty).compactMap { $0.asIssue?.id ?? $0.asPullRequest?.id }
                    + (data.created.nodes ?? .empty).compactMap { $0.asIssue?.id ?? $0.asPullRequest?.id }
                Task { try? await environment.fetch(RefreshRowsQuery(ids: Array(ids.prefix(50)))) }
            }
        }
    }
}

/// The refresh of `docs/recipes/discover-once.md`: the rows the lists show,
/// asked for again by id in one request, so each row re-renders with its new
/// fields and the lists' own query is left alone. Declared apart from the
/// screen: a view's `@Query` property resolves and fetches on appearance,
/// and this one is sent by hand, with the ids at hand.
@MainActor
struct TriageDocuments {
    @Query("""
        query RefreshRowsQuery($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on Issue { id ...IssueRow_issue @alias }
            ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
          }
        }
        """)
    var refreshRows: RefreshRowsQuery
}

/// One search result: an issue links to its screen; a pull request is shown.
struct TriageRow: View {
    let issue: (id: String, row: IssueRow_issue)?
    let pullRequest: PullRequestRow_pullRequest?

    var body: some View {
        if let issue {
            NavigationLink(value: IssueQuery(id: issue.id)) { IssueRow(issue: issue.row) }
        } else if let pullRequest {
            PullRequestRow(pullRequest: pullRequest)
        }
    }
}
