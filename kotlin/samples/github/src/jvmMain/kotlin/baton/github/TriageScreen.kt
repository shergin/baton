package baton.github

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import baton.Environment
import baton.Fragment
import baton.LocalBaton
import baton.Phase
import baton.Query
import baton.rememberQuery
import kotlinx.coroutines.launch

/** A pull request row; its author may be gone, and the row shows a ghost then. */
@Fragment(
    """
    fragment PullRequestRow_pullRequest on PullRequest {
      number
      title
      isDraft
      repository { nameWithOwner }
      author { login }
    }
    """,
)
@Composable
fun PullRequestRow(pullRequest: PullRequestRow_pullRequest) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("pull request")) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(pullRequest.title, style = MaterialTheme.typography.titleMedium)
            if (pullRequest.isDraft) Text("Draft", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(
            "${pullRequest.repository.nameWithOwner} #${pullRequest.number} · ${pullRequest.author?.login ?: "ghost"}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * Two searches, aliased, over the `SearchResultItem` union. The compiler
 * adds `__typename` to every abstract selection; the ingest keys each node
 * by its concrete type, so an issue seen here is the same record the issue
 * screen reads. Relay requires `@alias` on a spread inside an inline
 * fragment on a union, and so does Baton: the spread is then reachable only
 * through the nullable `asIssue`. Refresh fetches the query again; Refresh
 * rows asks for the rows shown by id, in one request, and leaves the
 * searches' own query alone.
 */
@Query(
    """
    query TriageQuery {
      viewer { login }
      assigned: search(query: "is:open assignee:@me", type: ISSUE, first: 30) {
        issueCount
        nodes {
          ... on Issue { id ...IssueRow_issue @alias }
          ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
        }
      }
      created: search(query: "is:open author:@me", type: ISSUE, first: 30) {
        issueCount
        nodes {
          ... on Issue { id ...IssueRow_issue @alias }
          ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
        }
      }
    }
    """,
)
@Composable
fun TriageScreen(onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val triage = rememberQuery(TriageQuery())
    val environment = LocalBaton.current
    val scope = rememberCoroutineScope()
    Column(modifier) {
        Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = { scope.launch { runCatching { triage.refetch() }.onFailure { println("refresh failed: $it") } } }) { Text("Refresh") }
            TextButton(
                onClick = {
                    // The lenses are read in the coroutine, which runs on the
                    // composition's dispatcher, the store's thread, wherever
                    // the click was delivered from.
                    scope.launch {
                        val data = (triage.phase as? Phase.Ready)?.data ?: return@launch
                        val ids = (assignedRows(data.assigned.nodes) + createdRows(data.created.nodes)).map { it.id }
                        runCatching { environment?.refreshRows(ids.take(50)) }.onFailure { println("refresh rows failed: $it") }
                    }
                },
            ) { Text("Refresh rows") }
        }
        if (triage.isRefreshing) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        PhaseView(triage.phase, retry = { triage.retry() }) { data ->
            LazyColumn(modifier = Modifier.testTag("triage")) {
                section("Assigned to ${data.viewer.login} · ${data.assigned.issueCount}", assignedRows(data.assigned.nodes), onSelect)
                section("Created by ${data.viewer.login} · ${data.created.issueCount}", createdRows(data.created.nodes), onSelect)
            }
        }
    }
}

/** One search result as a row: an issue, which opens its screen, or a pull request, which is shown; each with the node's id. */
private sealed interface TriageRow {
    val id: String

    data class Issue(override val id: String, val row: IssueRow_issue) : TriageRow
    data class PullRequest(override val id: String, val row: PullRequestRow_pullRequest) : TriageRow
}

// Each search's nodes are a lens class of their own, since the two aliased
// fields are two selections, so each is mapped to rows by its own type under
// a name of its own, since the two lists erase to one JVM signature. An
// issue whose row bubbled, one without an author, is no row.
private fun assignedRows(nodes: List<TriageQuery.Data.Assigned.Nodes>?): List<TriageRow> = nodes.orEmpty().mapNotNull { node ->
    node.asIssue?.let { issue -> issue.issueRow?.let { TriageRow.Issue(issue.id, it) } }
        ?: node.asPullRequest?.let { TriageRow.PullRequest(it.id, it.pullRequestRow) }
}

private fun createdRows(nodes: List<TriageQuery.Data.Created.Nodes>?): List<TriageRow> = nodes.orEmpty().mapNotNull { node ->
    node.asIssue?.let { issue -> issue.issueRow?.let { TriageRow.Issue(issue.id, it) } }
        ?: node.asPullRequest?.let { TriageRow.PullRequest(it.id, it.pullRequestRow) }
}

/** One search's rows under its title. */
private fun LazyListScope.section(title: String, rows: List<TriageRow>, onSelect: (String) -> Unit) {
    item(key = title) {
        Text(title, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.titleSmall)
    }
    items(rows, key = { "$title ${it.id}" }) { row ->
        when (row) {
            is TriageRow.Issue -> IssueRow(row.row, onClick = { onSelect(row.id) })
            is TriageRow.PullRequest -> PullRequestRow(row.row)
        }
    }
}

/**
 * The refresh of `docs/recipes/discover-once.md`: the rows the lists show,
 * asked for again by id in one request, so each row re-renders with its new
 * fields and the lists' own query is left alone. Sent by hand through the
 * environment, with the ids at hand, so it is hosted here and not on a
 * composable that would resolve it.
 */
@Query(
    $$"""
    query RefreshRowsQuery($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on Issue { id ...IssueRow_issue @alias }
        ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
      }
    }
    """,
)
suspend fun Environment.refreshRows(ids: List<String>) {
    if (ids.isEmpty()) return
    fetch(RefreshRowsQuery(ids = ids))
}
