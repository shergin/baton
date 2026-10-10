package baton.sample

import androidx.compose.foundation.clickable
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
import baton.rememberQuery

/**
 * The header a detail shows at once: the list fetched these fields, so the
 * lookup by id finds them in the store. Its origin and its last known
 * location open the location's screen.
 */
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
fun CharacterHeader(character: CharacterHeader_character, onOpen: (Destination) -> Unit) {
    Column(
        modifier = Modifier.onFirstDraw(Unit) { Measurement.detailDrawn() },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Avatar(character.image, size = 160)
        Text(character.name ?: "Unknown", style = MaterialTheme.typography.headlineMedium)
        Text(
            listOfNotNull(character.status, character.species, character.gender).joinToString(" · "),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            character.origin?.let { Place("Origin", it.name, it.id, onOpen) }
            character.location?.let { Place("Last seen", it.name, it.id, onOpen) }
        }
    }
}

/** A place's name under its label; a link to the location's screen when the API gave it an id, as it gives none to "unknown". */
@Composable
private fun Place(label: String, name: String?, id: String?, onOpen: (Destination) -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (id.isNullOrEmpty()) {
            Text(name ?: "Unknown")
        } else {
            Text(name ?: "Unknown", modifier = Modifier.clickable { onOpen(Destination.Location(id)) }, color = MaterialTheme.colorScheme.primary)
        }
    }
}

/**
 * Two operations: the header, usually answered by the store under the
 * `character` lookup, and the episodes, which only the detail needs; each
 * episode opens its screen.
 */
@Query(
    $$"""
    query CharacterHeaderQuery($id: ID!) {
      character(id: $id) { ...CharacterHeader_character }
    }
    """,
)
@Composable
fun CharacterScreen(id: String, onOpen: (Destination) -> Unit, modifier: Modifier = Modifier) {
    val header = rememberQuery(CharacterHeaderQuery(id = id))
    Column(modifier = modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PhaseView(header.phase, retry = { header.retry() }) { data ->
            data.character?.let { CharacterHeader(it.characterHeader, onOpen) }
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp))
        Episodes(id, onOpen)
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
private fun Episodes(id: String, onOpen: (Destination) -> Unit) {
    val episodes = rememberQuery(CharacterEpisodesQuery(id = id))
    Text("Episodes", style = MaterialTheme.typography.titleMedium)
    when (val phase = episodes.phase) {
        Phase.Loading -> CircularProgressIndicator(modifier = Modifier.padding(16.dp))
        is Phase.Failed -> Text(phase.error.message ?: phase.error.toString(), color = MaterialTheme.colorScheme.error)
        is Phase.Ready -> for (episode in phase.data.character?.episode.orEmpty()) {
            val episodeId = episode.id
            Column(
                modifier = Modifier.clickable(enabled = episodeId != null) { episodeId?.let { onOpen(Destination.Episode(it)) } }.padding(vertical = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
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
