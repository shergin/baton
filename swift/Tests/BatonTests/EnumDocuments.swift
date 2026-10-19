import Baton

/// Documents over the schema enum `Status`: a mutation reads a list of it,
/// whose response carries a value the schema does not declare, and a query
/// takes it as a variable and a list of it, which it sends as their text;
/// and over `EpisodeStatus`, which grows behind a `version` argument, read
/// with the argument and without it, two slots of one field.
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

    @Query("""
        query TestEpisodeStatus($id: ID!) {
          episode(id: $id) { id status hiatus: status(version: 2) }
        }
        """)
    var episodeStatus: TestEpisodeStatus
}
