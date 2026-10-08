package baton.sample

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import baton.Fragment
import baton.Phase
import baton.Query
import baton.isRefreshing
import baton.phase
import baton.rememberQuery
import baton.retry

/** A row declares exactly what it reads. */
@Fragment(
    """
    fragment CharacterRow_character on Character {
      name
      status
      species
      image
    }
    """,
)
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

/**
 * The list, one page at a time. It also spreads the detail header's
 * fragment, so a selected character's detail renders its header from the
 * store at once.
 */
@Query(
    $$"""
    query CharactersScreenQuery($page: Int) {
      characters(page: $page) {
        info { count pages next prev }
        results {
          id
          ...CharacterRow_character
          ...CharacterHeader_character
        }
      }
    }
    """,
)
@Composable
fun CharactersScreen(page: Int, onPage: (Int) -> Unit, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val characters = rememberQuery(CharactersScreenQuery(page = page))
    // The bar reads the page's info when the page is ready and stays through
    // a failure, so a page the API refused can be left.
    val info = (characters.phase as? Phase.Ready)?.data?.characters?.info
    Column(modifier) {
        Row(modifier = Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { onPage(info?.prev ?: (page - 1)) }, enabled = page > 1) { Text("Previous") }
            Text("Page $page of ${info?.pages ?: "…"}", modifier = Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
            TextButton(onClick = { info?.next?.let(onPage) }, enabled = info?.next != null) { Text("Next") }
        }
        if (characters.isRefreshing) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        PhaseView(characters.phase, retry = { characters.retry() }) { data ->
            LazyColumn(modifier = Modifier.onFirstDraw(page) { Measurement.listDrawn(page) }) {
                items(data.characters?.results.orEmpty(), key = { it.recordID.key }) { character ->
                    CharacterRow(character.characterRow, onClick = { character.id?.let(onSelect) })
                }
            }
        }
    }
}
