package baton.sample

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import baton.Fragment
import baton.Phase
import baton.Query
import baton.phase
import baton.rememberQuery
import baton.retry

/** The header a detail shows at once: the list fetched these fields, so the lookup by id finds them in the store. */
@Fragment(
    """
    fragment CharacterHeader_character on Character {
      name
      status
      species
      gender
      image
      origin { id name }
      location { id name }
    }
    """,
)
@Composable
fun CharacterHeader(character: CharacterHeader_character) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Avatar(character.image, size = 160)
        Text(character.name ?: "Unknown", style = MaterialTheme.typography.headlineMedium)
        Text(
            listOfNotNull(character.status, character.species, character.gender).joinToString(" · "),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Place("Origin", character.origin?.name)
            Place("Last seen", character.location?.name)
        }
    }
}

@Composable
private fun Place(label: String, name: String?) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(name ?: "Unknown")
    }
}

/**
 * Two operations: the header, usually answered by the store under the
 * `character` lookup, and the episodes, which only the detail needs.
 */
@Query(
    $$"""
    query CharacterHeaderQuery($id: ID!) {
      character(id: $id) { ...CharacterHeader_character }
    }
    """,
)
@Composable
fun CharacterScreen(id: String) {
    val header = rememberQuery(CharacterHeaderQuery(id = id))
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PhaseView(header.phase, retry = { header.retry() }) { data ->
            data.character?.let { CharacterHeader(it.characterHeader) }
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp))
        Episodes(id)
    }
}

@Query(
    $$"""
    query CharacterEpisodesQuery($id: ID!) {
      character(id: $id) {
        episode { id name episode air_date }
      }
    }
    """,
)
@Composable
private fun Episodes(id: String) {
    val episodes = rememberQuery(CharacterEpisodesQuery(id = id))
    Text("Episodes", style = MaterialTheme.typography.titleMedium)
    when (val phase = episodes.phase) {
        Phase.Loading -> CircularProgressIndicator(modifier = Modifier.padding(16.dp))
        is Phase.Failed -> Text(phase.error.message ?: phase.error.toString(), color = MaterialTheme.colorScheme.error)
        is Phase.Ready -> for (episode in phase.data.character?.episode.orEmpty()) {
            Column(modifier = Modifier.padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(episode.name ?: "Unknown")
                Text(
                    listOfNotNull(episode.episode, episode.air_date).joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
