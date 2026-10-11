package app

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Fragment
import baton.Phase
import baton.Query
import baton.rememberQuery

@Fragment("""
    fragment IssueRow_issue on Issue {
      number
      title
      author @required(action: LOG) { login }
    }
    """)
@Composable
fun IssueRow(issue: IssueRow_issue) {
    Text("#${issue.number} ${issue.title} by ${issue.author.login}")
}

@Query($$"""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) @catch {
        nameWithOwner
        description
        issues(first: 5, states: OPEN) {
          nodes { id ...IssueRow_issue }
        }
      }
    }
    """)
@Composable
fun RepositoryScreen(owner: String, name: String) {
    val query = rememberQuery(RepositoryQuery(owner = owner, name = name))
    when (val phase = query.phase) {
        is Phase.Ready -> {
            val caught = phase.data.repository
            val failure = caught.exceptionOrNull()
            val repo = caught.getOrNull()
            when {
                failure != null -> Text("Could not load the repository: ${failure.message}")
                repo == null -> Text("No such repository")
                else -> LazyColumn {
                    item { Text(repo.nameWithOwner) }
                    repo.description?.let { item { Text(it) } }
                    items(repo.issues.nodes.orEmpty(), key = { it.id }) { issue ->
                        // An issue whose author is gone reads as no row.
                        issue.issueRow?.let { IssueRow(it) }
                    }
                }
            }
        }
        Phase.Loading -> CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) { query.retry() }
    }
}
