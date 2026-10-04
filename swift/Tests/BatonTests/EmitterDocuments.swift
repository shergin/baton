import Baton

/// The documents behind the emitter tests, against the test schema: shapes
/// whose generated code once did not compile or read wrong. A spread alone
/// under an aliased `@catch` and `@catch(to: NULL)`, of a fragment without
/// an error policy and of one with `@throwOnFieldError`, on a link of the
/// fragment's own type and under a type condition on an interface; a field
/// and an aliased selection named like a type condition's accessor; fields
/// named like the fragments and the refetch query a lens refers to; a field
/// named like a spread's accessor; a connection whose edges' lens cannot be
/// named `Edges`; and a mutation whose
/// payload fields are named like the types an optimistic builder spells,
/// with a variable named `self`.
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

    @Query("""
        query TestConditionNames($id: ID!, $name: String!) {
          namesake(name: $name) {
            asCharacter: name
            ... on Character { status }
          }
          node(id: $id) {
            id
            ... on Episode @alias(as: "asCharacter") { name }
            ... on Character { name }
          }
        }
        """)
    var conditionNames: TestConditionNames

    @Fragment("""
        fragment TestProgramNames_character on Character
        @refetchable(queryName: "TestProgramNamesRefetchQuery") {
          testProgramNamesRefetchQuery: origin { name }
          testCaughtProfile_character: location { name }
          ...TestCaughtProfile_character
        }
        """)
    var programNames: TestProgramNames_character

    @Query("""
        query TestProgramNamesQuery($id: ID!) {
          character(id: $id) { ...TestProgramNames_character }
        }
        """)
    var programNamesQuery: TestProgramNamesQuery

    @Query("""
        query TestSpreadNames($id: ID!) {
          character(id: $id) { testCaughtStrict: species ...TestCaughtStrict_character }
        }
        """)
    var spreadNames: TestSpreadNames

    @Fragment("""
        fragment TestEdgesNames_character on Character {
          notes(first: 2) @connection(key: "TestEdgesNames_notes") {
            Edges: pageInfo { hasNextPage }
            edges { node { id text } }
          }
        }
        """)
    var edgesNames: TestEdgesNames_character

    @Query("""
        query TestEdgesNamesQuery($id: ID!) {
          character(id: $id) { ...TestEdgesNames_character }
        }
        """)
    var edgesNamesQuery: TestEdgesNamesQuery

    @Mutation("""
        mutation TestBuilderNames($id: ID!, $favorite: Boolean!, $self: ID!) {
          type: setFavorite(id: $id, favorite: $favorite) { character { id favorite } }
          self: setFavorite(id: $self, favorite: $favorite) { character { id favorite } }
          string: setFavorite(id: $id, favorite: $favorite) { character { id name } }
          sendable: setFavorite(id: $id, favorite: $favorite) { character { id favorite } }
        }
        """)
    var builderNames: TestBuilderNames.Action
}
