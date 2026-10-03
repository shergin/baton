import Baton

/// Documents whose selections depend on types and conditions: `@include` and
/// `@skip` both ways, a field repeated under a condition with other children,
/// a union whose members read disjoint fields, one alias under two types, an
/// interface only some members implement, an abstract selection read through
/// its own fields, one fragment spread twice and once more under a
/// condition, and caught fields and `__typename` under a condition in an
/// operation that throws on field errors.
@MainActor
struct ConditionDocuments {
    @Query("""
        query TestConditions($id: ID!, $withOrigin: Boolean!, $hideStatus: Boolean!) {
          character(id: $id) {
            name
            origin { id }
            origin @include(if: $withOrigin) { name dimension }
            status @skip(if: $hideStatus)
            ... @include(if: $withOrigin) { species }
          }
        }
        """)
    var conditions: TestConditions

    @Query("""
        query TestUnion($name: String!) {
          search(name: $name) {
            __typename
            ... on Character { label: name status }
            ... on Location { label: dimension type }
            ... on Episode { air_date }
            ... on Named { name }
          }
        }
        """)
    var union: TestUnion

    @Query("""
        query TestNodeFields($id: ID!) {
          node(id: $id) { id ... on Character { name } }
        }
        """)
    var nodeFields: TestNodeFields

    @Query("""
        query TestTwoSpreads($id: ID!, $again: Boolean!) {
          character(id: $id) { ...TestRow_character ...TestRow_character ...TestRow_character @include(if: $again) @alias(as: "again") }
        }
        """)
    var twoSpreads: TestTwoSpreads

    @Query("""
        query TestNodeDeferred($id: ID!) {
          node(id: $id) {
            id
            ... on Character { name }
            ...TestAppearances_character @defer @alias(as: "appearances")
          }
        }
        """)
    var nodeDeferred: TestNodeDeferred

    @Query("""
        query TestStrictConditions($id: ID!, $withStatus: Boolean!) @throwOnFieldError {
          character(id: $id) {
            name
            __typename @include(if: $withStatus)
            species @include(if: $withStatus)
            status @include(if: $withStatus) @catch
            origin @include(if: $withStatus) @catch { name }
          }
        }
        """)
    var strictConditions: TestStrictConditions
}
