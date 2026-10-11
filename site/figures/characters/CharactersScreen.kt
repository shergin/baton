package app

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Fragment
import baton.Phase
import baton.Query
import baton.rememberQuery

@Fragment("""
    fragment CharacterRow_character on Character {
      name
      status
      species
      image
    }
    """)
@Composable
fun CharacterRow(character: CharacterRow_character) {
    Row {
        Avatar(url = character.image)
        Column {
            Text(character.name ?: "Unknown")
            Text("${character.status ?: "?"} · ${character.species ?: "?"}")
        }
    }
}

@Query($$"""
    query CharactersQuery($page: Int) {
      characters(page: $page) {
        results { id ...CharacterRow_character }
      }
    }
    """)
@Composable
fun CharactersScreen(page: Int) {
    val query = rememberQuery(CharactersQuery(page = page))
    when (val phase = query.phase) {
        is Phase.Ready -> LazyColumn {
            items(phase.data.characters?.results.orEmpty(), key = { it.recordID.key }) {
                CharacterRow(it.characterRow)
            }
        }
        Phase.Loading -> CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) { query.retry() }
    }
}
