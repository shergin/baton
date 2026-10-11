package app

import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import baton.Fragment
import baton.Mutation
import baton.Phase
import baton.Query
import baton.rememberMutation
import baton.rememberQuery
import kotlinx.coroutines.launch

@Fragment("""
    fragment StarButton_repository on Repository {
      id
      viewerHasStarred
      stargazerCount
    }
    """)
@Mutation($$"""
    mutation StarButtonAddStar($input: AddStarInput!) {
      addStar(input: $input) {
        starrable { id viewerHasStarred ... on Repository { stargazerCount } }
      }
    }
    """)
@Mutation($$"""
    mutation StarButtonRemoveStar($input: RemoveStarInput!) {
      removeStar(input: $input) {
        starrable { id viewerHasStarred ... on Repository { stargazerCount } }
      }
    }
    """)
@Composable
fun StarButton(repository: StarButton_repository) {
    val addStar = rememberMutation(StarButtonAddStar)
    val removeStar = rememberMutation(StarButtonRemoveStar)
    val scope = rememberCoroutineScope()
    val starred = repository.viewerHasStarred
    OutlinedButton(
        onClick = {
            scope.launch {
                val id = repository.id
                val count = repository.stargazerCount
                if (starred) {
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
                } else {
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
            }
        },
        enabled = !addStar.isInFlight && !removeStar.isInFlight,
    ) {
        Text(if (starred) "★ ${repository.stargazerCount}" else "☆ ${repository.stargazerCount}")
    }
}

@Query($$"""
    query RepositoryQuery($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        ...StarButton_repository
      }
    }
    """)
@Composable
fun RepositoryScreen(owner: String, name: String) {
    val query = rememberQuery(RepositoryQuery(owner = owner, name = name))
    val phase = query.phase
    if (phase is Phase.Ready) phase.data.repository?.let { repo ->
        Text(repo.nameWithOwner)
        StarButton(repo.starButton)
    }
}
