import Baton
import SwiftUI

/// `node(id:)` is a lookup by id across types: an issue the triage list
/// fetched is already in the store, and the rest is fetched.
struct IssueScreen: View {
    @Query("""
        query IssueQuery($id: ID!) {
          node(id: $id) {
            ... on Issue { ...IssueDetail_issue @alias }
          }
        }
        """)
    var issue: IssueQuery

    var body: some View {
        PhaseView(phase: issue.phase, retry: issue.retry) { data in
            if let detail = data.node?.asIssue?.issueDetail {
                IssueDetail(issue: detail) { await issue.refetch() }
            } else {
                ContentUnavailableView("Not an issue", systemImage: "questionmark")
            }
        }
    }
}

struct IssueDetail: View {
    @Fragment("""
        fragment IssueDetail_issue on Issue {
          id
          number
          title
          bodyText
          createdAt
          state
          repository { nameWithOwner name owner { login } }
          author { login }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          comments(first: 30) {
            totalCount
            nodes { id bodyText createdAt author { login } }
          }
        }
        """)
    var issue: IssueDetail_issue
    let refetch: () async -> Void

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
                if let comments = issue.comments.nodes {
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(comment.author?.login ?? "ghost") · \(shortDate(comment.createdAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(comment.bodyText)
                        }
                        .padding(.vertical, 4)
                    }
                }
                CommentComposer(subjectID: issue.id, refetch: refetch)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("#\(issue.number)")
    }
}

/// Adds a comment. The new comment's record lands in the store, but the
/// issue's `comments` list is not told about it until the edge directives of
/// 0.4, so the composer refetches the issue after the commit.
struct CommentComposer: View {
    let subjectID: String
    let refetch: () async -> Void
    @State private var text = ""

    @Mutation("""
        mutation CommentComposerAddComment($input: AddCommentInput!) {
          addComment(input: $input) {
            commentEdge { node { id bodyText createdAt author { login } } }
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
                        try await addComment(input: .object(["subjectId": .string(subjectID), "body": .string(body)]))
                        text = ""
                        await refetch()
                    } catch {
                        print("comment failed: \(error)")
                    }
                }
            }
            .disabled(text.isEmpty || addComment.isInFlight)
        }
    }
}
