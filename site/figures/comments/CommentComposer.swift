import Baton
import SwiftUI

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
