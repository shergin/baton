package baton.github

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import baton.Fragment
import baton.Mutation
import baton.MutationAction
import baton.Query
import baton.rememberMutation
import baton.rememberQuery
import kotlinx.coroutines.launch

/**
 * An issue row declares exactly what it reads; `author` is an interface
 * (`Actor`), read through the record's concrete type. The row requires an
 * author: an issue whose author is gone reads as no row, and the
 * environment logs where, as Relay's `@required(action: LOG)` does.
 */
@Fragment(
    """
    fragment IssueRow_issue on Issue {
      number
      title
      state
      repository { nameWithOwner }
      author @required(action: LOG) { login }
    }
    """,
)
@Composable
fun IssueRow(issue: IssueRow_issue, onClick: () -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(issue.title, style = MaterialTheme.typography.titleMedium)
        Text(
            "${issue.repository.nameWithOwner} #${issue.number} · ${issue.author.login} · ${issue.state.word}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** The schema's `IssueState` as a word; a state this build does not know shows its text. */
val IssueState.word: String
    get() = when (this) {
        IssueState.OPEN -> "open"
        IssueState.CLOSED -> "closed"
        is IssueState.Undeclared -> scalarText.lowercase()
    }

/**
 * A repository by owner and name. One that does not exist comes back as
 * null with a field error; `@catch` turns the field into a result, so the
 * screen shows the server's reason instead of guessing.
 */
@Query(
    $$"""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) @catch {
        nameWithOwner
        description
        forkCount
        ...StarButton_repository
        ...IssueList_repository
      }
    }
    """,
)
@Composable
fun RepositoryScreen(owner: String, name: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val repository = rememberQuery(RepositoryQuery(owner = owner, name = name))
    Box(modifier) {
        PhaseView(repository.phase, retry = { repository.retry() }) { data ->
            val caught = data.repository
            val failure = caught.exceptionOrNull()
            val found = caught.getOrNull()
            when {
                failure != null -> Message("Could not load the repository: ${failure.message}")
                found == null -> Message("No such repository.")
                else -> IssueList(found.issueList, onSelect = onSelect) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(found.nameWithOwner, style = MaterialTheme.typography.headlineSmall)
                        found.description?.let { Text(it) }
                        Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("${found.forkCount} forks", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            StarButton(found.starButton)
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun Message(text: String) {
    Box(modifier = Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Open issues as a cursor connection, under a [header] that scrolls with
 * them. The fragment is refetchable, so the connection lens fetches the
 * next page with the fragment's own query; the pages merge into one list in
 * the store, and `hasNext` and `isLoadingNext` are read from it like any
 * other field. The last item, a spinner, is composed only when the list is
 * scrolled to its end, and asks for the next page then.
 */
@Fragment(
    $$"""
    fragment IssueList_repository on Repository
    @refetchable(queryName: "IssueListPaginationQuery")
    @argumentDefinitions(count: {type: "Int", defaultValue: 20}, cursor: {type: "String"}) {
      issues(first: $count, after: $cursor, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC})
        @connection(key: "IssueList_issues") {
        totalCount
        edges { node { id ...IssueRow_issue } }
      }
    }
    """,
)
@Composable
fun IssueList(repository: IssueList_repository, onSelect: (String) -> Unit, header: @Composable () -> Unit) {
    val issues = repository.issues
    LazyColumn(modifier = Modifier.testTag("issues")) {
        item {
            header()
            HorizontalDivider()
            Text(
                "${issues.totalCount} open issues",
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                style = MaterialTheme.typography.titleSmall,
            )
        }
        items(issues.nodes, key = { it.id }) { issue ->
            // The row requires an author; an issue without one reads as no row.
            val id = issue.id
            issue.issueRow?.let { row -> IssueRow(row, onClick = { onSelect(id) }) }
        }
        if (issues.hasNext) {
            item(key = "next page") {
                Box(modifier = Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                LaunchedEffect(issues.pageInfo.endCursor) {
                    runCatching { issues.loadNext() }.onFailure { println("next page failed: $it") }
                }
            }
        }
    }
}

/**
 * The star toggle. Each mutation is an action; the optimistic response is
 * typed, goes through the same ingest as a server response, and is reverted
 * if the server fails.
 */
@Fragment(
    """
    fragment StarButton_repository on Repository {
      id
      viewerHasStarred
      stargazerCount
    }
    """,
)
@Mutation(
    $$"""
    mutation StarButtonAddStar($input: AddStarInput!) {
      addStar(input: $input) {
        starrable { id viewerHasStarred ... on Repository { stargazerCount } }
      }
    }
    """,
)
@Mutation(
    $$"""
    mutation StarButtonRemoveStar($input: RemoveStarInput!) {
      removeStar(input: $input) {
        starrable { id viewerHasStarred ... on Repository { stargazerCount } }
      }
    }
    """,
)
@Composable
fun StarButton(repository: StarButton_repository) {
    // One composable hosts the fragment it renders and the two mutations it
    // calls; the markers repeat.
    val addStar = rememberMutation(StarButtonAddStar)
    val removeStar = rememberMutation(StarButtonRemoveStar)
    val scope = rememberCoroutineScope()
    val starred = repository.viewerHasStarred
    OutlinedButton(
        onClick = {
            // The lens is read in the coroutine, which runs on the
            // composition's dispatcher, the store's thread, wherever the
            // click was delivered from.
            scope.launch {
                val id = repository.id
                val count = repository.stargazerCount
                runCatching { if (starred) unstar(removeStar, id, count) else star(addStar, id, count) }
                    .onFailure { println("star toggle failed: $it") }
            }
        },
        enabled = !addStar.isInFlight && !removeStar.isInFlight,
        modifier = Modifier.testTag("star"),
    ) {
        Text(if (starred) "\u2605 Starred \u00b7 ${repository.stargazerCount}" else "\u2606 Star \u00b7 ${repository.stargazerCount}")
    }
}

/**
 * Stars the repository [id], whose count is [count], flipping the star and
 * the count before the server answers. `starrable` is an interface, so the
 * optimistic response names the concrete type.
 */
private suspend fun star(addStar: MutationAction<StarButtonAddStar, StarButtonAddStar.Data>, id: String, count: Int) {
    addStar(
        input = AddStarInput(starrableId = id),
        optimistic = StarButtonAddStar.OptimisticResponse(
            StarButtonAddStar.OptimisticResponse.AddStar(
                StarButtonAddStar.OptimisticResponse.AddStar.Starrable(
                    __typename = "Repository", id = id, viewerHasStarred = true, stargazerCount = count + 1,
                ),
            ),
        ),
    )
}

/** Unstars the repository [id], as [star] stars it. */
private suspend fun unstar(removeStar: MutationAction<StarButtonRemoveStar, StarButtonRemoveStar.Data>, id: String, count: Int) {
    removeStar(
        input = RemoveStarInput(starrableId = id),
        optimistic = StarButtonRemoveStar.OptimisticResponse(
            StarButtonRemoveStar.OptimisticResponse.RemoveStar(
                StarButtonRemoveStar.OptimisticResponse.RemoveStar.Starrable(
                    __typename = "Repository", id = id, viewerHasStarred = false, stargazerCount = count - 1,
                ),
            ),
        ),
    )
}
