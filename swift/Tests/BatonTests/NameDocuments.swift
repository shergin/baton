import Baton

/// A document on a type and fields named as the generated code names its
/// own: the shared `Types` enum, the runtime's module `Baton`, and `Type`
/// and `Protocol`, which Swift reads after a dot as metatypes.
@MainActor
struct NameDocuments {
    @Query("""
        query TestNames {
          types { Type Protocol Baton }
        }
        """)
    var names: TestNames
}
