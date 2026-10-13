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
    query EpisodesQuery($id: ID!) {
      character(id: $id) {
        name
        episode @stream(label: "episodes", initialCount: 3) { id name }
      }
    }
    """)
@Composable
fun EpisodeList(id: String) {
    val query = rememberQuery(EpisodesQuery(id = id))
    val phase = query.phase
    if (phase is Phase.Ready) phase.data.character?.let { character ->
        LazyColumn {
            items(character.episode, key = { it.recordID.key }) { episode -> Text(episode.name ?: "Untitled") }
            if (query.isRefreshing) item { CircularProgressIndicator() }
        }
    }
}
