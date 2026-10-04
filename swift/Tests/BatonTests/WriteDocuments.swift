import Baton

/// The documents behind the write-side tests, against the test schema: a
/// mutation with a payload, one that reads it through a fragment on the
/// mutation type, a union, and a lookup by id across types.
@MainActor
struct WriteDocuments {
    @Fragment("""
        fragment TestFavorite_character on Character {
          id
          name
          favorite
        }
        """)
    var favorite: TestFavorite_character

    @Mutation("""
        mutation TestSetFavorite($id: ID!, $favorite: Boolean!) {
          setFavorite(id: $id, favorite: $favorite) {
            character { id name favorite }
          }
        }
        """)
    var setFavorite: TestSetFavorite.Action

    @Mutation("""
        mutation TestRename($id: ID!, $name: String!) {
          rename(id: $id, name: $name) {
            character { id name }
          }
        }
        """)
    var rename: TestRename.Action

    @Mutation("""
        mutation TestRenameWithOrigin($id: ID!, $name: String!, $withOrigin: Boolean!) {
          rename(id: $id, name: $name) {
            character { id name origin @include(if: $withOrigin) { id name } }
          }
        }
        """)
    var renameWithOrigin: TestRenameWithOrigin.Action

    @Fragment("""
        fragment TestRenamePayload_mutation on Mutation {
          rename(id: $id, name: $name) {
            character { id name }
          }
        }
        """)
    var renamePayload: TestRenamePayload_mutation

    @Mutation("""
        mutation TestRenameThroughFragment($id: ID!, $name: String!) {
          ...TestRenamePayload_mutation
        }
        """)
    var renameThroughFragment: TestRenameThroughFragment.Action

    @Query("""
        query TestSearch($name: String!) {
          search(name: $name) {
            __typename
            ... on Character { id name }
            ... on Location { id name dimension }
          }
        }
        """)
    var search: TestSearch

    @Query("""
        query TestSearchOrigins($name: String!) {
          search(name: $name) {
            ... on Character { origin { name } }
          }
        }
        """)
    var searchOrigins: TestSearchOrigins

    @Query("""
        query TestNode($id: ID!) {
          node(id: $id) {
            __typename
            ... on Character { id name }
            ... on Episode { id name }
          }
        }
        """)
    var node: TestNode
}
