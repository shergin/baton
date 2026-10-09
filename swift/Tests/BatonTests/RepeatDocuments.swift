import Baton

/// The documents behind the tests of a repeated object, against the test
/// schema: a mutation whose payload appends a character's episodes as nodes,
/// the edge directive on the plural field itself, and one that appends each
/// episode's cast, the edge directive on a field of the episode's selection.
@MainActor
struct RepeatDocuments {
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
