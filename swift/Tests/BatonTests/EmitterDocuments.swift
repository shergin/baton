import Baton

/// The documents behind the emitter tests, against the test schema: shapes
/// whose generated code once did not compile or read wrong. Here, a spread
/// alone under an aliased `@catch` and `@catch(to: NULL)`, of a fragment
/// without an error policy and of one with `@throwOnFieldError`, on a link
/// of the fragment's own type and under a type condition on an interface.
@MainActor
struct EmitterDocuments {
    @Fragment("""
        fragment TestCaughtProfile_character on Character {
          name
          origin { name }
        }
        """)
    var caughtProfile: TestCaughtProfile_character

    @Fragment("""
        fragment TestCaughtStrict_character on Character @throwOnFieldError {
          species
        }
        """)
    var caughtStrict: TestCaughtStrict_character

    @Query("""
        query TestCaughtSpreads($id: ID!) {
          character(id: $id) {
            id
            ... @alias(as: "profile") @catch { ...TestCaughtProfile_character }
            ... @alias(as: "nulledProfile") @catch(to: NULL) { ...TestCaughtProfile_character }
            ... @alias(as: "strict") @catch { ...TestCaughtStrict_character }
            ... @alias(as: "nulledStrict") @catch(to: NULL) { ...TestCaughtStrict_character }
          }
          node(id: $id) {
            id
            ... on Character @alias(as: "profile") @catch { ...TestCaughtProfile_character }
          }
        }
        """)
    var caughtSpreads: TestCaughtSpreads
}
