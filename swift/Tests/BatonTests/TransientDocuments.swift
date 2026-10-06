import Baton

/// Documents over what the tests' `baton.json` keeps off the image: a query
/// that reads the transient root field `secrets` beside a character, and one
/// that reads a character linking a record of the transient type `Secret`.
@MainActor
struct TransientDocuments {
    @Query("""
        query TestSecrets($code: String!) { secrets(code: $code) { id body } character(id: "1") { id name } }
        """)
    var secrets: TestSecrets

    @Query("""
        query TestCharacterSecret { character(id: "1") { id name secret { id body } } }
        """)
    var characterSecret: TestCharacterSecret
}
