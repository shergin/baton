import Baton

/// The documents behind the delivery tests, against the test schema: field
/// errors read plainly and through `@catch`, `@required` in its three actions,
/// `@throwOnFieldError` with the schema's `@semanticNonNull`, a deferred
/// fragment, in an operation that throws too and in one that selects the
/// fragment's field outside it as well, an operation that throws with a
/// spread that does not, and a subscription that appends to a connection.
@MainActor
struct DeliveryDocuments {
    @Fragment("""
        fragment TestProfile_character on Character {
          name
          origin @required(action: NONE) { name }
          status @required(action: LOG)
          image @catch
          location @catch { name dimension }
          gender @catch(to: NULL)
        }
        """)
    var profile: TestProfile_character

    @Fragment("""
        fragment TestStrict_character on Character @throwOnFieldError {
          species
          type @required(action: THROW)
        }
        """)
    var strict: TestStrict_character

    @Fragment("""
        fragment TestAppearances_character on Character {
          episode { name air_date }
        }
        """)
    var appearances: TestAppearances_character

    @Query("""
        query TestProfileQuery($id: ID!) {
          character(id: $id) {
            ...TestProfile_character
            ...TestStrict_character @alias(as: "strict")
            ...TestAppearances_character @defer
          }
        }
        """)
    var profileQuery: TestProfileQuery

    @Query("""
        query TestStrictQuery($id: ID!) @throwOnFieldError {
          character(id: $id) { name species }
        }
        """)
    var strictQuery: TestStrictQuery

    @Query("""
        query TestStrictDeferred($id: ID!) @throwOnFieldError {
          character(id: $id) { id name ...TestAppearances_character @defer }
        }
        """)
    var strictDeferred: TestStrictDeferred

    @Query("""
        query TestOverlapQuery($id: ID!) {
          character(id: $id) { name episode { id } ...TestAppearances_character @defer }
        }
        """)
    var overlapQuery: TestOverlapQuery

    @Fragment("""
        fragment TestName_character on Character { name }
        """)
    var name: TestName_character

    @Query("""
        query TestThrowingSpread($id: ID!) @throwOnFieldError {
          character(id: $id) { species ...TestName_character }
        }
        """)
    var throwingSpread: TestThrowingSpread

    @Query("""
        query TestNullsOnError($id: ID!) {
          character(id: $id) { name }
        }
        """)
    var nullsOnError: TestNullsOnError

    @Query("""
        query TestRosterQuery($page: Int) {
          characters(page: $page) {
            results { id name status @required(action: NONE) }
          }
        }
        """)
    var rosterQuery: TestRosterQuery

    @Subscription("""
        subscription TestNoteAdded($characterId: ID!, $connections: [ID!]!) {
          noteAdded(characterId: $characterId) {
            noteEdge @appendEdge(connections: $connections) { cursor node { id text } }
          }
        }
        """)
    var noteAdded: TestNoteAdded
}
