package app

import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import baton.Fragment
import baton.Phase
import baton.Query
import baton.rememberQuery

@Fragment($$"""
    fragment IssueList_repository on Repository
    @refetchable(queryName: "IssueListPaginationQuery")
    @argumentDefinitions(
      count: {type: "Int", defaultValue: 20}
      cursor: {type: "String"}
    ) {
      issues(first: $count, after: $cursor, states: OPEN)
      @connection(key: "IssueList_issues") {
        edges { node { id ...IssueRow_issue } }
      }
    }
    """)
@Composable
fun IssueList(repository: IssueList_repository) {
    val issues = repository.issues
    LazyColumn {
        items(issues.nodes, key = { it.id }) {
            IssueRow(it.issueRow)
        }
        if (issues.hasNext) item {
            CircularProgressIndicator()
            LaunchedEffect(issues) {
                runCatching { issues.loadNext() }
            }
        }
    }
}

@Fragment("""
    fragment IssueRow_issue on Issue {
      number
      title
    }
    """)
@Composable
fun IssueRow(issue: IssueRow_issue) {
    Text("#${issue.number} ${issue.title}")
}

@Query($$"""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        ...IssueList_repository
      }
    }
    """)
@Composable
fun RepositoryScreen(owner: String, name: String) {
    val query = rememberQuery(RepositoryQuery(owner = owner, name = name))
    when (val phase = query.phase) {
        is Phase.Ready -> phase.data.repository?.let { repo ->
            Text(repo.nameWithOwner)
            IssueList(repo.issueList)
        }
        Phase.Loading -> CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) { query.retry() }
    }
}
