import Baton

/// The documents behind the list tests, against the test schema: a
/// refetchable fragment paginating a connection of notes forward and one
/// paginating it backward, the screens that spread them with and without
/// arguments, the mutations that edit the connection declaratively by edge
/// and by node, one that only deletes a record, an aliased spread, a
/// connection whose nodes defer a fragment, and a query that fetches two
/// pages of one connection.
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

    @Fragment("""
        fragment TestRecentNotes_character on Character
        @refetchable(queryName: "TestRecentNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          notes(last: $count, before: $cursor) @connection(key: "TestRecentNotes_notes") {
            edges { node { id text } }
          }
        }
        """)
    var recentNotes: TestRecentNotes_character

    @Query("""
        query TestRecentNotesQuery($id: ID!) {
          character(id: $id) { ...TestRecentNotes_character }
        }
        """)
    var recentNotesQuery: TestRecentNotesQuery

    @Mutation("""
        mutation TestAddNoteNode($characterId: ID!, $text: String!, $connections: [ID!]!) {
          addNote(characterId: $characterId, text: $text) {
            note @appendNode(connections: $connections, edgeTypeName: "NoteEdge") { id text }
          }
        }
        """)
    var addNoteNode: TestAddNoteNode.Action

    @Mutation("""
        mutation TestAddNoteNodeFirst($characterId: ID!, $text: String!, $connections: [ID!]!) {
          addNote(characterId: $characterId, text: $text) {
            note @prependNode(connections: $connections, edgeTypeName: "NoteEdge") { id text }
          }
        }
        """)
    var addNoteNodeFirst: TestAddNoteNodeFirst.Action

    @Mutation("""
        mutation TestAddNoteNodeOfAnotherType($characterId: ID!, $text: String!, $connections: [ID!]!) {
          addNote(characterId: $characterId, text: $text) {
            note @appendNode(connections: $connections, edgeTypeName: "PageInfo") { id text }
          }
        }
        """)
    var addNoteNodeOfAnotherType: TestAddNoteNodeOfAnotherType.Action

    @Mutation("""
        mutation TestDeleteNote($id: ID!) {
          removeNote(id: $id) { removedNoteId @deleteRecord }
        }
        """)
    var deleteNote: TestDeleteNote.Action

    @Query("""
        query TestAliasQuery($id: ID!) {
          character(id: $id) { ...TestRow_character @alias(as: "row") }
        }
        """)
    var aliasQuery: TestAliasQuery

    @Fragment("""
        fragment TestDeferredNotes_character on Character
        @refetchable(queryName: "TestDeferredNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          notes(first: $count, after: $cursor) @connection(key: "TestDeferredNotes_notes") {
            edges { node { id ...TestNoteText_note @defer(label: "noteText") } }
          }
        }
        """)
    var deferredNotes: TestDeferredNotes_character

    @Fragment("""
        fragment TestNoteText_note on Note { text }
        """)
    var noteText: TestNoteText_note

    @Query("""
        query TestTwoPagesQuery($id: ID!) {
          character(id: $id) {
            id
            notes(first: 2) @connection(key: "TestTwoPages_notes") { edges { node { id text } } }
          }
          node(id: $id) {
            ... on Character {
              notes(first: 2, after: "c2") @connection(key: "TestTwoPages_notes") { edges { node { id text } } }
            }
          }
        }
        """)
    var twoPages: TestTwoPagesQuery
}
