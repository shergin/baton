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
