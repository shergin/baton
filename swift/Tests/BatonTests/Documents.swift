import Baton

/// The documents the tests compile against the Rick and Morty schema. The
/// operation that produced the recorded fixture, a list that prefetches the
/// header a detail screen reads, the detail operation itself, a second
/// operation on the detail's root field, one that states its cache
/// expiration, and one under the module-qualified marker in a raw literal.
@MainActor
struct Documents {
    @Query("""
        query Fixture($page: Int) {
          characters(page: $page) {
            info { count pages next prev }
            results {
              id name status species type gender image created
              origin { id name type dimension created }
              location { id name type dimension created }
              episode {
                id name air_date episode created
                characters { id name image }
              }
            }
          }
        }
        """)
    var fixture: Fixture

    @Fragment("""
        fragment TestRow_character on Character {
          name
          status
          image
        }
        """)
    var row: TestRow_character

    @Fragment("""
        fragment TestHeader_character on Character {
          name
          status
          species
          image
          origin { name }
        }
        """)
    var header: TestHeader_character

    @Query("""
        query TestList($page: Int) {
          characters(page: $page) {
            results { ...TestRow_character ...TestHeader_character }
          }
        }
        """)
    var list: TestList

    @Query("""
        query TestHeaderQuery($id: ID!) {
          character(id: $id) { ...TestHeader_character }
        }
        """)
    var headerQuery: TestHeaderQuery

    @Query("""
        query TestEpisodesQuery($id: ID!) {
          character(id: $id) {
            episode { id name }
          }
        }
        """)
    var episodesQuery: TestEpisodesQuery

    @Query("""
        query TestFreshCharacter($id: ID!) @cacheExpiration(seconds: 30) {
          character(id: $id) { id name }
        }
        """)
    var freshCharacter: TestFreshCharacter

    @Baton.Query(#"""
        query TestQualifiedQuery($id: ID!) {
          character(id: $id) { id name }
        }
        """#)
    var qualifiedQuery: TestQualifiedQuery
}
