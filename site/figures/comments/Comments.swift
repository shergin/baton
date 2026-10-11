import Baton
import SwiftUI

struct IssueComments: View {
    @Fragment("""
    fragment IssueComments_issue on Issue
    @refetchable(queryName: "IssueCommentsPaginationQuery")
    @argumentDefinitions(count: {type: "Int", defaultValue: 30}, cursor: {type: "String"}) {
      id
      comments(first: $count, after: $cursor) @connection(key: "IssueComments_comments") {
        totalCount
        edges { node { id bodyText author { login } } }
      }
    }
    """)
    var issue: IssueComments_issue

    var body: some View {
        Text("\(issue.comments.totalCount) comments")
        ForEach(issue.comments.nodes) { comment in
            Text("\(comment.author?.login ?? "ghost"): \(comment.bodyText)")
        }
        CommentComposer(subjectID: issue.id, connectionID: issue.comments.connectionID)
    }
}

struct CommentComposer: View {
    let subjectID: String
    let connectionID: String
    @State private var text = ""

    @Mutation("""
    mutation CommentComposerAddComment($input: AddCommentInput!, $connections: [ID!]!) {
      addComment(input: $input) {
        commentEdge @appendEdge(connections: $connections) {
          node { id bodyText author { login } }
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
                    try await addComment(
                        input: AddCommentInput(body: body, subjectId: subjectID),
                        connections: [connectionID]
                    )
                    text = ""
                }
            }
            .disabled(text.isEmpty || addComment.isInFlight)
        }
    }
}
