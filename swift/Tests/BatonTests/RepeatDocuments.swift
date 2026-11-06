import Baton

/// Documents over a list that may print one character more than once: the
/// character's fields alone, whose repeats the ingest may take by comparing,
/// and a page of its notes, once under a connection, whose repeats it reads
/// whole, and once as a plain field, whose repeats it may take. Two
/// mutations append a character's episodes as nodes, the edge directive on
/// the plural field itself, and each episode's cast, the edge directive on a
/// field of the episode's selection.
@MainActor
struct RepeatDocuments {
    @Query("""
        query TestRepeatedCharacters($page: Int) {
          characters(page: $page) {
            results { id name status }
          }
        }
        """)
    var repeatedCharacters: TestRepeatedCharacters

    @Query("""
        query TestRepeatedConnectionNotes {
          characters(page: 1) {
            results {
              id
              notes(first: 1) @connection(key: "TestRepeatedConnectionNotes_notes") { edges { node { id text } } }
            }
          }
        }
        """)
    var repeatedConnectionNotes: TestRepeatedConnectionNotes

    @Query("""
        query TestRepeatedPlainNotes {
          characters(page: 1) {
            results {
              id
              notes(first: 1) { edges { cursor node { id text } } pageInfo { endCursor hasNextPage } }
            }
          }
        }
        """)
    var repeatedPlainNotes: TestRepeatedPlainNotes

    @Mutation("""
        mutation TestAppendEpisodeNodes($id: ID!, $name: String!, $connections: [ID!]!) {
          rename(id: $id, name: $name) {
            character {
              id
              episode @appendNode(connections: $connections, edgeTypeName: "NoteEdge") { id name air_date episode }
            }
          }
        }
        """)
    var appendEpisodeNodes: TestAppendEpisodeNodes.Action

    @Mutation("""
        mutation TestAppendCastNodes($id: ID!, $name: String!, $connections: [ID!]!) {
          rename(id: $id, name: $name) {
            character {
              id
              episode {
                id
                name
                air_date
                episode
                characters @appendNode(connections: $connections, edgeTypeName: "NoteEdge") { id }
              }
            }
          }
        }
        """)
    var appendCastNodes: TestAppendCastNodes.Action
}
