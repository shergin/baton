package app

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import baton.Fragment
import baton.Mutation
import baton.rememberMutation
import kotlinx.coroutines.launch

@Fragment($$"""
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
@Composable
fun IssueComments(issue: IssueComments_issue) {
    val comments = issue.comments
    Column {
        Text("${comments.totalCount} comments")
        for (comment in comments.nodes) {
            Text("${comment.author?.login ?: "ghost"}: ${comment.bodyText}")
        }
        CommentComposer(subjectID = issue.id, connectionID = comments.connectionID)
    }
}

@Mutation($$"""
    mutation CommentComposerAddComment($input: AddCommentInput!, $connections: [ID!]!) {
      addComment(input: $input) {
        commentEdge @appendEdge(connections: $connections) {
          node { id bodyText author { login } }
        }
      }
    }
    """)
@Composable
fun CommentComposer(subjectID: String, connectionID: String) {
    val addComment = rememberMutation(CommentComposerAddComment)
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    Row {
        OutlinedTextField(value = text, onValueChange = { text = it })
        Button(
            onClick = {
                val body = text
                scope.launch {
                    addComment(
                        input = AddCommentInput(body = body, subjectId = subjectID),
                        connections = listOf(connectionID),
                    )
                    text = ""
                }
            },
            enabled = text.isNotBlank() && !addComment.isInFlight,
        ) { Text("Comment") }
    }
}
