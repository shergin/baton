package baton.github

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import baton.Fragment
import baton.Generated
import baton.Mutation
import baton.MutationAction
import baton.Phase
import baton.Query
import baton.phase
import baton.rememberMutation
import baton.rememberQuery
import baton.retry
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.launch

/**
 * `node(id:)` is a lookup by id across types: an issue's fields the list
 * fetched are already in the store, and the rest is fetched. The spread is
 * aliased, so the lens exposes it as `detail`.
 */
@Query(
    $$"""
    query IssueQuery($id: ID!) {
      node(id: $id) {
        ... on Issue { ...IssueDetail_issue @alias(as: "detail") }
      }
    }
    """,
)
@Composable
fun IssueScreen(id: String, modifier: Modifier = Modifier) {
    val issue = rememberQuery(IssueQuery(id = id))
    Column(modifier) {
        PhaseView(issue.phase, retry = { issue.retry() }) { data ->
            val detail = data.node?.asIssue?.detail
            if (detail == null) Message("Not an issue.") else IssueDetail(detail)
        }
    }
}

/**
 * The issue with its comments as a cursor connection. The fragment is
 * refetchable, so the connection loads further pages with its own query,
 * and the composer appends to it declaratively.
 */
@Fragment(
    $$"""
    fragment IssueDetail_issue on Issue
    @refetchable(queryName: "IssueDetailPaginationQuery")
    @argumentDefinitions(count: {type: "Int", defaultValue: 30}, cursor: {type: "String"}) {
      id
      number
      title
      bodyText
      createdAt
      state
      repository { nameWithOwner }
      author { login }
      comments(first: $count, after: $cursor) @connection(key: "IssueDetail_comments") {
        totalCount
        edges { node { id bodyText createdAt author { login } } }
      }
    }
    """,
)
@Composable
fun IssueDetail(issue: IssueDetail_issue) {
    val comments = issue.comments
    val scope = rememberCoroutineScope()
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(issue.title, style = MaterialTheme.typography.headlineSmall)
        Text(
            "${issue.repository.nameWithOwner} #${issue.number} · ${issue.author?.login ?: "ghost"} · ${shortDate(issue.createdAt)} · ${issue.state.word}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (issue.bodyText.isNotEmpty()) Text(issue.bodyText)
        HorizontalDivider()
        Text("${comments.totalCount} comments", style = MaterialTheme.typography.titleMedium)
        for (comment in comments.nodes) {
            Column(modifier = Modifier.testTag("comment").padding(vertical = 4.dp)) {
                Text(
                    "${comment.author?.login ?: "ghost"} · ${shortDate(comment.createdAt)}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(comment.bodyText)
            }
        }
        if (comments.hasNext) {
            TextButton(
                onClick = { scope.launch { runCatching { comments.loadNext() }.onFailure { println("next comments failed: $it") } } },
                enabled = !comments.isLoadingNext,
            ) { Text(if (comments.isLoadingNext) "Loading…" else "Load more comments") }
        }
        CommentComposer(subjectID = issue.id, connectionID = comments.connectionID)
    }
}

/** Who is signed in, once the server has said; the composer's optimistic comment is theirs. */
@Query(
    """
    query ViewerQuery {
      viewer { id login }
    }
    """,
)
@Composable
private fun rememberViewer(): ViewerQuery.Data.Viewer? {
    val viewer = rememberQuery(ViewerQuery())
    return (viewer.phase as? Phase.Ready)?.data?.viewer
}

/**
 * Adds a comment. The payload's edge is appended to the comments connection
 * by `@appendEdge`, so the list grows without a refetch; the connection is
 * named through the `connections` variable, as in Relay. An optimistic
 * comment by the viewer shows at once and is replaced by the server's when
 * it lands, or removed if the server refuses it.
 */
@Mutation(
    $$"""
    mutation CommentComposerAddComment($input: AddCommentInput!, $connections: [ID!]!) {
      addComment(input: $input) {
        commentEdge @appendEdge(connections: $connections) {
          node { id bodyText createdAt author { login } }
        }
      }
    }
    """,
)
@Composable
fun CommentComposer(subjectID: String, connectionID: String) {
    // `rememberMutation` takes the generated companion as an `OperationType`,
    // which is behind the `Generated` opt-in, and cannot infer the operation
    // from it; the sample opts in here and names the action's type. See the
    // README.
    @OptIn(Generated::class)
    val addComment: MutationAction<CommentComposerAddComment, CommentComposerAddComment.Data> = rememberMutation(CommentComposerAddComment)
    val viewer = rememberViewer()
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            placeholder = { Text("Leave a comment") },
            modifier = Modifier.weight(1f).testTag("composer"),
        )
        Button(
            onClick = {
                val author = viewer ?: return@Button
                val body = text
                // The field empties at once, as the comment appears; a refusal puts the text back.
                text = ""
                scope.launch {
                    runCatching {
                        addComment(
                            input = AddCommentInput(body = body, subjectId = subjectID),
                            connections = listOf(connectionID),
                            optimistic = optimisticComment(body, author),
                        )
                    }.onFailure {
                        println("comment failed: $it")
                        if (text.isEmpty()) text = body
                    }
                }
            },
            // The optimistic comment is the viewer's, so the button waits for the viewer.
            enabled = text.isNotBlank() && viewer != null && !addComment.isInFlight,
        ) { Text("Comment") }
    }
}

/**
 * The comment as the server will answer it, under a client id the server's
 * edge replaces: the [body] by the [viewer], now.
 */
private fun optimisticComment(body: String, viewer: ViewerQuery.Data.Viewer): CommentComposerAddComment.OptimisticResponse =
    CommentComposerAddComment.OptimisticResponse(
        CommentComposerAddComment.OptimisticResponse.AddComment(
            CommentComposerAddComment.OptimisticResponse.AddComment.CommentEdge(
                CommentComposerAddComment.OptimisticResponse.AddComment.CommentEdge.Node(
                    id = "client:optimistic-comment:${UUID.randomUUID()}",
                    bodyText = body,
                    createdAt = Instant.now().toString(),
                    author = CommentComposerAddComment.OptimisticResponse.AddComment.CommentEdge.Node.Author(__typename = "User", login = viewer.login, id = viewer.id),
                ),
            ),
        ),
    )

/** An ISO 8601 timestamp from the API, as its date. */
fun shortDate(iso: String): String = iso.substringBefore('T')
