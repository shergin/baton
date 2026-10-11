package app

import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import baton.Phase
import baton.Query
import baton.rememberQuery

@Query($$"""
    query CharacterQuery($id: ID!) @cacheExpiration(seconds: 300) {
      character(id: $id) { ...CharacterHeader_character }
    }
    """)
@Composable
fun CharacterScreen(id: String) {
    val query = rememberQuery(CharacterQuery(id = id))
    when (val phase = query.phase) {
        is Phase.Ready -> phase.data.character?.let { character ->
            CharacterHeader(character.characterHeader)
        }
        Phase.Loading -> CircularProgressIndicator()
        is Phase.Failed -> ErrorView(phase.error) { query.retry() }
    }
}
