package app

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Phase
import baton.Query
import baton.rememberQuery

@Query($$"""
    query IssuesQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        issues(first: 20, states: OPEN) {
          nodes { id ...IssueRow_issue }
        }
      }
    }
    """)
@Composable
fun IssuesScreen(owner: String, name: String) {
    val query = rememberQuery(
        IssuesQuery(owner = owner, name = name),
    )
    when (val phase = query.phase) {
        is Phase.Ready -> phase.data.repository?.let { repo ->
            LazyColumn {
                item { Text(repo.nameWithOwner) }
                items(repo.issues.nodes.orEmpty()) {
                    IssueRow(it.issueRow)
                }
            }
        }
        Phase.Loading ->
            CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) {
            query.retry()
        }
    }
}
