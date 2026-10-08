package baton.sample.apollo

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import baton.sample.apollo.graphql.CharacterEpisodesQuery
import baton.sample.apollo.graphql.CharacterHeaderQuery
import baton.sample.apollo.graphql.CharactersScreenQuery
import baton.sample.apollo.graphql.fragment.CharacterHeader_character
import baton.sample.apollo.graphql.fragment.CharacterRow_character
import com.apollographql.apollo.api.Optional
import com.apollographql.apollo.exception.CacheMissException

// The Baton sample's screens (`samples/shared`), their layout copied and
// their data read from Apollo's generated models.

@Composable
fun CharacterRow(character: CharacterRow_character, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar(character.image, size = 44)
        Column {
            Text(character.name ?: "Unknown", style = MaterialTheme.typography.titleMedium)
            Text(
                listOfNotNull(character.status, character.species).joinToString(" · "),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** The list, one page at a time, watched. */
@Composable
fun CharactersScreen(page: Int, onPage: (Int) -> Unit, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val characters = watchQuery(remember(page) { CharactersScreenQuery(page = Optional.present(page)) })
    // The bar reads the page's info when the page is ready and stays through
    // a failure, so a page the API refused can be left.
    val info = characters.response?.data?.characters?.info
    Column(modifier) {
        Row(modifier = Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { onPage(info?.prev ?: (page - 1)) }, enabled = page > 1) { Text("Previous") }
            Text("Page $page of ${info?.pages ?: "…"}", modifier = Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
            TextButton(onClick = { info?.next?.let(onPage) }, enabled = info?.next != null) { Text("Next") }
        }
        PhaseView(characters) { data ->
            LazyColumn(modifier = Modifier.onFirstDraw(page) { Measurement.listDrawn(page) }) {
                items(data.characters?.results.orEmpty().filterNotNull(), key = { it.id ?: it.hashCode().toString() }) { character ->
                    CharacterRow(character.characterRow_character, onClick = { character.id?.let(onSelect) })
                }
            }
        }
    }
}

@Composable
fun CharacterHeader(character: CharacterHeader_character) {
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
 * Two queries: the header, answered by the cache under the `character`
 * field policy, and the episodes, which only the detail needs.
 */
@Composable
fun CharacterScreen(id: String) {
    val header = watchQuery(remember(id) { CharacterHeaderQuery(id = id) })
    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        PhaseView(header) { data ->
            data.character?.let { CharacterHeader(it.characterHeader_character) }
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp))
        Episodes(id)
    }
}

@Composable
private fun Episodes(id: String) {
    val episodes = watchQuery(remember(id) { CharacterEpisodesQuery(id = id) })
    Text("Episodes", style = MaterialTheme.typography.titleMedium)
    val response = episodes.response
    val data = response?.data
    when {
        data != null -> for (episode in data.character?.episode.orEmpty().filterNotNull()) {
            Column(modifier = Modifier.padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(episode.name ?: "Unknown")
                Text(
                    listOfNotNull(episode.episode, episode.air_date).joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        response == null || response.exception is CacheMissException ->
            CircularProgressIndicator(modifier = Modifier.padding(16.dp))
        else -> Text(response.exception?.message ?: "no data", color = MaterialTheme.colorScheme.error)
    }
}
