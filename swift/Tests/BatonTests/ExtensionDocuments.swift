import Baton

/// Documents over the client schema extension in `spec/tests/extensions.graphql`:
/// a query that reads two client fields beside a character's server fields,
/// and one that reads the client-only list of drafts beside a server field,
/// with a draft linking a character the server has.
@MainActor
struct ExtensionDocuments {
    @Query("""
        query TestPinnedCharacter($id: ID!) { character(id: $id) { id name status isPinned note } }
        """)
    var pinnedCharacter: TestPinnedCharacter

    @Query("""
        query TestDrafts { drafts { id text about { id name } } character(id: "1") { id name } }
        """)
    var drafts: TestDrafts
}
