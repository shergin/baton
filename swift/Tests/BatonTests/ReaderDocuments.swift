import Baton

/// The documents behind the reader tests, against the test schema: a root
/// field and a link `@required` all the way up, a non-null list under
/// `@catch`, one scope holding two keys with variables and two spreads
/// with arguments, and fields named like the module's shared enums.
@MainActor
struct ReaderDocuments {
    @Query("""
        query TestRequiredOrigin($id: ID!) {
          character(id: $id) @required(action: NONE) {
            id
            origin @required(action: NONE) { id name }
          }
        }
        """)
    var requiredOrigin: TestRequiredOrigin

    @Fragment("""
        fragment TestThrowingOrigin_character on Character @throwOnFieldError {
          origin @required(action: THROW) { name }
        }
        """)
    var throwingOrigin: TestThrowingOrigin_character

    @Query("""
        query TestCaughtEpisodes($id: ID!) {
          character(id: $id) { id caught: episode @catch { name } }
        }
        """)
    var caughtEpisodes: TestCaughtEpisodes

    @Query("""
        query TestTwoScopes($a: ID!, $b: ID!) {
          first: character(id: $a) { id name ...TestNotes_character @arguments(count: 1) }
          second: character(id: $b) { id name ...TestNotes_character @arguments(count: 3) }
        }
        """)
    var twoScopes: TestTwoScopes

    @Query("""
        query TestReservedNames($id: ID!) {
          sites: character(id: $id) { id ...TestNotes_character @arguments(count: 1) }
          types: character(id: $id) { id }
          slots: character(id: $id) { id }
        }
        """)
    var reservedNames: TestReservedNames
}
