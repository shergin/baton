import Baton

/// The documents behind the reader tests, against the test schema: a root
/// field and a link `@required` all the way up, a non-null list under
/// `@catch`, one scope holding two keys with variables and two spreads
/// with arguments, fields named like the module's shared enums and like the
/// Swift types, keywords and attribute a lens spells, two fields whose
/// lenses would take one name, with an error policy and with a required
/// field, a type condition in an operation that throws on field errors, a
/// link and a list of links an operation that throws reads through,
/// variables named like Swift's keywords, a `@required(action: LOG)` field
/// below a non-null link, and deferred spreads with and without `@catch` in
/// operations that throw.
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

    @Query("""
        query TestSwiftNames($id: ID!) {
          type: character(id: $id) { id }
          self: character(id: $id) { id }
          protocol: character(id: $id) { id }
          any: character(id: $id) { id }
          mainActor: character(id: $id) { id }
          baton: character(id: $id) { id }
          abstractSlots: character(id: $id) { id }
          result: character(id: $id) { id }
          optional: character(id: $id) { id }
          string: character(id: $id) { id }
          int: character(id: $id) { id }
          double: character(id: $id) { id }
          bool: character(id: $id) { id }
          owner: character(id: $id) { id }
          caught: character(id: $id) @catch { id }
          node(id: $id) { id }
          tokenizer { ratio count flag }
        }
        """)
    var swiftNames: TestSwiftNames

    @Query("""
        query TestCollidingErrors($id: ID!) @throwOnFieldError {
          types: character(id: $id) { id }
          typesLens: character(id: $id) { id name }
        }
        """)
    var collidingErrors: TestCollidingErrors

    @Query("""
        query TestCollidingRequired($id: ID!) {
          types: character(id: $id) { id }
          typesLens: character(id: $id) @required(action: NONE) { id name @required(action: NONE) }
        }
        """)
    var collidingRequired: TestCollidingRequired

    @Query("""
        query TestThrowingNode($id: ID!) @throwOnFieldError {
          node(id: $id) { id ... on Character { name } }
        }
        """)
    var throwingNode: TestThrowingNode

    @Query("""
        query TestStrictOrigin($id: ID!) @throwOnFieldError {
          character(id: $id) { id origin { id name } }
        }
        """)
    var strictOrigin: TestStrictOrigin

    @Query("""
        query TestStrictEpisodes($id: ID!) @throwOnFieldError {
          character(id: $id) { id episode { id name } }
        }
        """)
    var strictEpisodes: TestStrictEpisodes

    @Query("""
        query TestKeywordVariables($where: ID!, $in: String!) {
          character(id: $where) { id }
          search(name: $in) { __typename }
        }
        """)
    var keywordVariables: TestKeywordVariables

    @Fragment("""
        fragment TestLogEdges_connection on NoteConnection {
          edges @required(action: LOG) { cursor }
        }
        """)
    var logEdges: TestLogEdges_connection

    @Fragment("""
        fragment TestLoggedNotes_character on Character {
          notes(first: 1) { totalCount ...TestLogEdges_connection }
        }
        """)
    var loggedNotes: TestLoggedNotes_character

    @Fragment("""
        fragment TestCaughtAppearances_character on Character {
          episode @catch { name }
        }
        """)
    var caughtAppearances: TestCaughtAppearances_character

    @Query("""
        query TestCaughtPartQuery($id: ID!) @throwOnFieldError {
          character(id: $id) { id name ...TestCaughtAppearances_character @defer }
        }
        """)
    var caughtPart: TestCaughtPartQuery

    @Query("""
        query TestUncaughtPartQuery($id: ID!) @throwOnFieldError {
          character(id: $id) { id name ...TestAppearances_character @defer }
        }
        """)
    var uncaughtPart: TestUncaughtPartQuery

    @Fragment("""
        fragment TestOriginAndEpisode_character on Character {
          origin { name }
          episode { name }
        }
        """)
    var originAndEpisode: TestOriginAndEpisode_character

    @Query("""
        query TestTwoFieldPartQuery($id: ID!) {
          character(id: $id) { id name ...TestOriginAndEpisode_character @defer }
        }
        """)
    var twoFieldPart: TestTwoFieldPartQuery
}
