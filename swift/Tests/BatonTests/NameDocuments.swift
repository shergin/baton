import Baton

/// Documents on types and fields named as Swift and the generated code name
/// their own: the shared `Types` enum, the runtime's module `Baton`, `Type`
/// and `Protocol`, which Swift reads after a dot as metatypes, and `Set`,
/// the type of the shared file's sets of types.
@MainActor
struct NameDocuments {
    @Query("""
        query TestNames {
          types { Type Protocol Baton }
        }
        """)
    var names: TestNames

    @Query("""
        query TestSpellings {
          spellings {
            ... on Spelled { label }
            ... on Baton { id }
            ... on Type { id }
            ... on Protocol { id }
            ... on Set { id }
          }
        }
        """)
    var spellings: TestSpellings
}
