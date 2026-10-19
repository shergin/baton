import Baton

/// Documents on types and fields named as Swift and the generated code name
/// their own: the shared `Types` enum, the runtime's module `Baton`, `Type`
/// and `Protocol`, which Swift reads after a dot as metatypes, `Set`, the
/// type of the shared file's sets of types, and `Any`, which Swift lets no
/// member take; and root fields capitalized as AniList's are, `Episode`,
/// spelled like its type, `Viewer`, named otherwise, `GenreCollection`, of
/// scalars, and `Notification`, the name of a Foundation type.
@MainActor
struct NameDocuments {
    @Query("""
        query TestNames {
          types { Type Protocol Baton Any }
        }
        """)
    var names: TestNames

    @Query("""
        query TestCaughtNames {
          types @catch(to: RESULT) { Baton }
        }
        """)
    var caughtNames: TestCaughtNames

    @Query("""
        query TestSpellings {
          spellings {
            ... on Spelled { label }
            ... on Baton { id }
            ... on Type { id }
            ... on Protocol { id }
            ... on Set { id }
            ... on Any { id }
          }
        }
        """)
    var spellings: TestSpellings

    @Query("""
        query TestCapitalizedRoots($id: ID!) {
          Episode(id: $id) { id name }
          Viewer { id name }
          GenreCollection
          Notification { __typename }
        }
        """)
    var capitalizedRoots: TestCapitalizedRoots
}
