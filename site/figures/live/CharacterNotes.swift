import Baton
import SwiftUI

struct CharacterNotes: View {
    @Fragment("""
    fragment CharacterNotes_character on Character
    @refetchable(queryName: "CharacterNotesPaginationQuery")
    @argumentDefinitions(count: {type: "Int", defaultValue: 10}, cursor: {type: "String"}) {
      id
      notes(first: $count, after: $cursor) @connection(key: "CharacterNotes_notes") {
        edges { node { id text } }
      }
    }
    """)
    var character: CharacterNotes_character

    @Subscription("""
    subscription NoteAdded($characterId: ID!, $connections: [ID!]!) {
      noteAdded(characterId: $characterId) {
        noteEdge @appendEdge(connections: $connections) {
          node { id text }
        }
      }
    }
    """)
    var noteAdded: NoteAdded

    init(character: CharacterNotes_character) {
        self.character = character
        noteAdded = NoteAdded(characterId: character.id ?? "", connections: [character.notes.connectionID])
    }

    var body: some View {
        ForEach(character.notes.nodes) { note in
            Text(note.text ?? "")
        }
    }
}
