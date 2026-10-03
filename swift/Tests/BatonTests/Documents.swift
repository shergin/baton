import Baton

/// The documents the tests compile against the Rick and Morty schema. The
/// operation that produced the recorded fixture, a list that prefetches the
/// header a detail screen reads, the detail operation itself, and a second
/// operation on the detail's root field.
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
}
