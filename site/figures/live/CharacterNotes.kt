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

@Fragment($$"""
    fragment CharacterNotes_character on Character
    @refetchable(queryName: "CharacterNotesPaginationQuery")
    @argumentDefinitions(count: {type: "Int", defaultValue: 10}, cursor: {type: "String"}) {
      id
      notes(first: $count, after: $cursor) @connection(key: "CharacterNotes_notes") {
        edges { node { id text } }
      }
    }
    """)
@Subscription($$"""
    subscription NoteAdded($characterId: ID!, $connections: [ID!]!) {
      noteAdded(characterId: $characterId) {
        noteEdge @appendEdge(connections: $connections) {
          node { id text }
        }
      }
    }
    """)
@Composable
fun CharacterNotes(character: CharacterNotes_character) {
    rememberSubscription(NoteAdded(characterId = character.id.orEmpty(), connections = listOf(character.notes.connectionID)))
    Column {
        for (note in character.notes.nodes) {
            Text(note.text.orEmpty())
        }
    }
}
