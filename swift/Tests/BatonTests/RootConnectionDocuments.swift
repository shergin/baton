import Baton

/// The documents behind a connection on the query root: a refetchable
/// fragment on `Query` paginating the root's notes, and the screen that
/// spreads it.
@MainActor
struct RootConnectionDocuments {
    @Fragment("""
        fragment TestRootNotes_query on Query
        @refetchable(queryName: "TestRootNotesPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 2}, cursor: {type: "String"}) {
          notes(first: $count, after: $cursor) @connection(key: "TestRootNotes_notes") {
            totalCount
            edges { node { id text } }
          }
        }
        """)
    var rootNotes: TestRootNotes_query

    @Query("""
        query TestRootNotesQuery { ...TestRootNotes_query }
        """)
    var rootNotesQuery: TestRootNotesQuery
}
