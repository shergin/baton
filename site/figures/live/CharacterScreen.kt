package app

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import baton.Fragment
import baton.Phase
import baton.Query
import baton.Subscription
import baton.rememberQuery
import baton.rememberSubscription

@Query($$"""
    query CharacterQuery($id: ID!) {
      character(id: $id) {
        name
        ...CharacterNotes_character @defer
      }
    }
    """)
@Composable
fun CharacterScreen(id: String) {
    val query = rememberQuery(CharacterQuery(id = id))
    val phase = query.phase
    if (phase is Phase.Ready) phase.data.character?.let { character ->
        Text(character.name ?: "Unknown")
        val notes = character.characterNotes
        if (notes != null) CharacterNotes(notes) else CircularProgressIndicator()
    }
}
