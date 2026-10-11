package app

import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Fragment
import baton.Phase
import baton.Query
import baton.rememberQuery

@Fragment("""
    fragment CharacterValue_character on Character @inline {
      id
      name
      status
      episode { id }
    }
    """)
object Rules

fun isSeriesRegular(character: CharacterValue_character): Boolean =
    character.status == "Alive" && character.episode.size > 10

@Query($$"""
    query CharacterQuery($id: ID!) {
      character(id: $id) {
        name
        ...CharacterValue_character
      }
    }
    """)
@Composable
fun CharacterScreen(id: String) {
    val query = rememberQuery(CharacterQuery(id = id))
    val phase = query.phase
    if (phase is Phase.Ready) phase.data.character?.let { character ->
        // The spread's getter builds the value from the record, now.
        val value = character.characterValue
        Text(character.name ?: "Unknown")
        if (isSeriesRegular(value)) Text("A series regular")
        Button(onClick = { share(value) }) { Text("Share") }
    }
}
