import Baton

/// The documents behind the list tests, against the test schema: a
/// refetchable fragment paginating a connection of notes forward and one
/// paginating it backward, the screens that spread them with and without
/// arguments, the mutations that edit the connection declaratively by edge
/// and by node, one that only deletes a record, an aliased spread, a
/// connection whose nodes defer a fragment, a query that fetches two
/// pages of one connection, and refetchable fragments paginating forward
/// and backward with fields named like the fragment and its refetch query,
/// in its lens and in the connection's, and a refetchable fragment on a
/// note paginating its author's notes, a link below the fragment's type.
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

    @Fragment("""
        fragment TestHiddenNotes_character on Character
        @refetchable(queryName: "TestHiddenNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          TestHiddenNotes_character: name
          TestHiddenNotesPaginationQuery: status
          notes(first: $count, after: $cursor) @connection(key: "TestHiddenNotes_notes") {
            TestHiddenNotes_character: totalCount
            TestHiddenNotesPaginationQuery: totalCount
            edges { node { id text } }
          }
        }
        """)
    var hiddenNotes: TestHiddenNotes_character

    @Query("""
        query TestHiddenNotesQuery($id: ID!) {
          character(id: $id) { ...TestHiddenNotes_character }
        }
        """)
    var hiddenNotesQuery: TestHiddenNotesQuery

    @Fragment("""
        fragment TestHiddenRecentNotes_character on Character
        @refetchable(queryName: "TestHiddenRecentNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          notes(last: $count, before: $cursor) @connection(key: "TestHiddenRecentNotes_notes") {
            TestHiddenRecentNotes_character: totalCount
            TestHiddenRecentNotesPaginationQuery: totalCount
            edges { node { id text } }
          }
        }
        """)
    var hiddenRecentNotes: TestHiddenRecentNotes_character

    @Query("""
        query TestHiddenRecentNotesQuery($id: ID!) {
          character(id: $id) { ...TestHiddenRecentNotes_character }
        }
        """)
    var hiddenRecentNotesQuery: TestHiddenRecentNotesQuery

    @Fragment("""
        fragment TestAuthorNotes_note on Note
        @refetchable(queryName: "TestAuthorNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          id
          author {
            id
            name
            notes(first: $count, after: $cursor) @connection(key: "TestAuthorNotes_notes") {
              edges { node { id text } }
            }
          }
        }
        """)
    var authorNotes: TestAuthorNotes_note

    @Query("""
        query TestAuthorNotesQuery($id: ID!) {
          node(id: $id) { ...TestAuthorNotes_note @alias(as: "note") }
        }
        """)
    var authorNotesQuery: TestAuthorNotesQuery
}
