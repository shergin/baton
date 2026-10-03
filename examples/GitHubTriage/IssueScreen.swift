import Baton
import SwiftUI

/// `node(id:)` is a lookup by id across types: an issue the triage list
/// fetched is already in the store, and the rest is fetched. The spread is
/// aliased, so the lens exposes it as `detail`.
struct IssueScreen: View {
    @Query("""
        query IssueQuery($id: ID!) {
          node(id: $id) {
            ... on Issue { ...IssueDetail_issue @alias(as: "detail") }
          }
        }
        """)
    var issue: IssueQuery

    var body: some View {
        PhaseView(phase: issue.phase, retry: issue.retry) { data in
            if let detail = data.node?.asIssue?.detail {
                IssueDetail(issue: detail)
            } else {
                ContentUnavailableView("Not an issue", systemImage: "questionmark")
            }
        }
    }
}

/// The issue with its comments as a cursor connection. The fragment is
/// refetchable, so the connection loads further pages with its own query, and
/// the composer appends to it declaratively.
struct IssueDetail: View {
    @Fragment("""
        fragment IssueDetail_issue on Issue
        @refetchable(queryName: "IssueDetailPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 30}, cursor: {type: "String"}) {
          id
          number
          title
          bodyText
          createdAt
          state
          repository { nameWithOwner name owner { login } }
          author { login }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          comments(first: $count, after: $cursor) @connection(key: "IssueDetail_comments") {
            totalCount
            edges { node { id bodyText createdAt author { login } } }
          }
        }
        """)
    var issue: IssueDetail_issue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(issue.title).font(.title2.bold())
                HStack {
                    NavigationLink(value: RepositoryQuery(owner: issue.repository.owner.login, name: issue.repository.name)) {
                        Text(issue.repository.nameWithOwner)
                    }
                    Text("#\(issue.number) · \(issue.author?.login ?? "ghost") · \(shortDate(issue.createdAt)) · \(issue.state.lowercased())")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if !issue.bodyText.isEmpty {
                    Text(issue.bodyText).textSelection(.enabled)
                }
                if let groups = issue.reactionGroups, !groups.isEmpty {
                    HStack {
                        ForEach(groups) { group in
                            if group.reactors.totalCount > 0 {
                                Text("\(group.content.lowercased()) \(group.reactors.totalCount)")
                                    .font(.caption)
                                    .padding(4)
                                    .background(group.viewerHasReacted ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                }
                Divider()
                Text("\(issue.comments.totalCount) comments").font(.headline)
                ForEach(issue.comments.nodes) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(comment.author?.login ?? "ghost") · \(shortDate(comment.createdAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(comment.bodyText)
                    }
                    .padding(.vertical, 4)
                }
                if issue.comments.hasNext {
                    Button(issue.comments.isLoadingNext ? "Loading…" : "Load more comments") {
                        Task { try? await issue.comments.loadNext() }
                    }
                    .disabled(issue.comments.isLoadingNext)
                }
                CommentComposer(subjectID: issue.id, connectionID: issue.comments.connectionID)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("#\(issue.number)")
    }
}

/// Adds a comment. The payload's edge is appended to the comments connection
/// by `@appendEdge`, so the list grows without a refetch; the connection is
/// named through the `connections` variable, as in Relay.
struct CommentComposer: View {
    let subjectID: String
    let connectionID: String
    @State private var text = ""

    @Mutation("""
        mutation CommentComposerAddComment($input: AddCommentInput!, $connections: [ID!]!) {
          addComment(input: $input) {
            commentEdge @appendEdge(connections: $connections) {
              node { id bodyText createdAt author { login } }
            }
          }
        }
        """)
    var addComment: CommentComposerAddComment.Action

    var body: some View {
        HStack {
            TextField("Leave a comment", text: $text)
            Button("Comment") {
                let body = text
                Task {
                    do {
                        try await addComment(
                            input: .object(["subjectId": .string(subjectID), "body": .string(body)]),
                            connections: [connectionID]
                        )
                        text = ""
                    } catch {
                        print("comment failed: \(error)")
                    }
                }
            }
            .disabled(text.isEmpty || addComment.isInFlight)
        }
    }
}
