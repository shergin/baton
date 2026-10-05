import Baton

/// A document whose storage keys hold what a key written as text would
/// misread: a dollar sign and a comma inside strings, a variable inside a
/// list and one inside an input object; and the same list and input object
/// bound as a fragment's arguments.
@MainActor
struct KeyDocuments {
    @Query("""
        query TestKeys($id: ID!, $name: String) {
          search(name: "$0.00") { __typename }
          character(id: "a,b") { name }
          charactersByIds(ids: [$id, "2"]) { name }
          characters(filter: {status: "Alive", name: $name}) { info { count } }
        }
        """)
    var keys: TestKeys

    @Fragment("""
        fragment TestKeyArguments_query on Query
        @argumentDefinitions(ids: {type: "[ID!]!"}, filter: {type: "FilterCharacter"}) {
          charactersByIds(ids: $ids) { name }
          characters(filter: $filter) { info { count } }
        }
        """)
    var keyArguments: TestKeyArguments_query

    /// Relay counts a variable used only inside a list or an input object
    /// that `@arguments` passes as unused, so the query reads both
    /// variables beside the spread too.
    @Query("""
        query TestSpreadKeys($id: ID!, $name: String) {
          character(id: $id) { name }
          named: characters(filter: {name: $name}) { info { count } }
          ...TestKeyArguments_query @arguments(ids: [$id, "2"], filter: {status: "Alive", name: $name})
        }
        """)
    var spreadKeys: TestSpreadKeys

    /// The rows of a list holding one field twice: under constant arguments,
    /// a key the compiler emits, and under a variable, a key each owner
    /// renders. Its counts are used by no other document, so this one meets
    /// both keys first.
    @Query("""
        query TestNoteCounts($page: Int, $count: Int) {
          characters(page: $page) {
            results {
              id
              name
              pinned: notes(first: 97) { totalCount }
              recent: notes(first: $count) { totalCount }
            }
          }
        }
        """)
    var noteCounts: TestNoteCounts
}
