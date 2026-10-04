import Baton

/// A document whose storage keys hold what a key written as text would
/// misread: a dollar sign and a comma inside strings, a variable inside a
/// list and one inside an input object.
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
}
