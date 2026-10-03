import Baton

/// The documents behind the list tests, against the test schema: a
/// refetchable fragment paginating a connection of notes, the screens that
/// spread it with and without arguments, the mutations that edit the
/// connection declaratively, and an aliased spread.
@MainActor
struct ListDocuments {
    @Fragment("""
        fragment TestNotes_character on Character
        @refetchable(queryName: "TestNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          name
          notes(first: $count, after: $cursor) @connection(key: "TestNotes_notes") {
            totalCount
            edges { node { id text } }
          }
        }
        """)
    var notes: TestNotes_character

    @Query("""
        query TestNotesQuery($id: ID!) {
          character(id: $id) { ...TestNotes_character }
        }
        """)
    var notesQuery: TestNotesQuery

    @Query("""
        query TestNotesSizedQuery($id: ID!, $size: Int) {
          character(id: $id) { ...TestNotes_character @arguments(count: $size) }
        }
        """)
    var sizedQuery: TestNotesSizedQuery

    @Mutation("""
        mutation TestAddNote($characterId: ID!, $text: String!, $connections: [ID!]!) {
          addNote(characterId: $characterId, text: $text) {
            noteEdge @appendEdge(connections: $connections) { cursor node { id text } }
          }
        }
        """)
    var addNote: TestAddNote.Action

    @Mutation("""
        mutation TestAddNoteFirst($characterId: ID!, $text: String!, $connections: [ID!]!) {
          addNote(characterId: $characterId, text: $text) {
            noteEdge @prependEdge(connections: $connections) { cursor node { id text } }
          }
        }
        """)
    var addNoteFirst: TestAddNoteFirst.Action

    @Mutation("""
        mutation TestRemoveNote($id: ID!, $connections: [ID!]!) {
          removeNote(id: $id) {
            removedNoteId @deleteEdge(connections: $connections)
            deleted: removedNoteId @deleteRecord
          }
        }
        """)
    var removeNote: TestRemoveNote.Action

    @Query("""
        query TestAliasQuery($id: ID!) {
          character(id: $id) { ...TestRow_character @alias(as: "row") }
        }
        """)
    var aliasQuery: TestAliasQuery
}
