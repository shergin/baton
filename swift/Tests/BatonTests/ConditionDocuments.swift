import Baton

/// Documents whose selections depend on types and conditions: `@include` and
/// `@skip` both ways, a field repeated under a condition with other children,
/// a union whose members read disjoint fields, one alias under two types, an
/// interface only some members implement, an abstract selection read through
/// its own fields, and one fragment spread twice and once more under a
/// condition.
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
}
