package baton.sample

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import baton.Query
import baton.rememberQuery

/**
 * An episode and its cast. The cast spreads the row's fragment and the
 * detail header's, as the list does, so a cast member's detail renders its
 * header from the store at once; a character seen in the list, in a cast
 * and among a location's residents is one record.
 */
@Query(
    $$"""
    query EpisodeQuery($id: ID!) {
      episode(id: $id) {
        name
        episode
        air_date
        characters { id ...CharacterRow_character ...CharacterHeader_character }
      }
    }
    """,
)
@Composable
fun EpisodeScreen(id: String, onOpen: (Destination) -> Unit, modifier: Modifier = Modifier) {
    val episode = rememberQuery(EpisodeQuery(id = id))
    PhaseView(episode.phase, retry = { episode.retry() }) { data ->
        val found = data.episode ?: return@PhaseView Message("No such episode.")
        LazyColumn(modifier = modifier.fillMaxSize()) {
            item {
                Heading(found.name, listOfNotNull(found.episode, found.air_date).joinToString(" · "), section = "Cast")
            }
            items(found.characters, key = { it.recordID.key }) { character ->
                CharacterRow(character.characterRow, onClick = { character.id?.let { onOpen(Destination.Character(it)) } })
            }
        }
    }
}

/** A location and its residents, shaped as the episode screen is. */
@Query(
    $$"""
    query LocationQuery($id: ID!) {
      location(id: $id) {
        name
        type
        dimension
        residents { id ...CharacterRow_character ...CharacterHeader_character }
      }
    }
    """,
)
@Composable
fun LocationScreen(id: String, onOpen: (Destination) -> Unit, modifier: Modifier = Modifier) {
    val location = rememberQuery(LocationQuery(id = id))
    PhaseView(location.phase, retry = { location.retry() }) { data ->
        val found = data.location ?: return@PhaseView Message("No such location.")
        LazyColumn(modifier = modifier.fillMaxSize()) {
            item {
                Heading(found.name, listOfNotNull(found.type, found.dimension).joinToString(" · "), section = "Residents")
            }
            items(found.residents, key = { it.recordID.key }) { character ->
                CharacterRow(character.characterRow, onClick = { character.id?.let { onOpen(Destination.Character(it)) } })
            }
        }
    }
}

/** A screen's name and the line under it, then the title of the list that follows. */
@Composable
private fun Heading(name: String?, detail: String, section: String) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp)) {
        Text(name ?: "Unknown", style = MaterialTheme.typography.headlineSmall)
        Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    HorizontalDivider()
    Text(section, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.titleSmall)
}

@Composable
internal fun Message(text: String) {
    Text(text, modifier = Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
}
