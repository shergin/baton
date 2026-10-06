import Baton

/// Documents over the schema enum `Status`: a mutation reads a list of it,
/// whose response carries a value the schema does not declare, and a query
/// takes it as a variable and a list of it, which it sends as their text.
@MainActor
struct EnumDocuments {
    @Mutation("""
        mutation TestSetStatuses { setLists { statuses } }
        """)
    var setStatuses: TestSetStatuses.Action

    @Query("""
        query TestCharactersWithStatus($status: Status!, $any: [Status!]) {
          charactersWithStatus(status: $status, any: $any) { name }
        }
        """)
    var charactersWithStatus: TestCharactersWithStatus
}
