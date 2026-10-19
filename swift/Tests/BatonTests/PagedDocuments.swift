import Baton

/// The documents behind the paged lists, against the test schema: two
/// queries that page two lists of one container on the query root, so that
/// their first pages are one server record with one page info, as AniList's
/// `Page` is, and a fragment on a character that pages its friends, a list
/// whose container hangs off an entity, with the screen that spreads it.
@MainActor
struct PagedDocuments {
    @Query("""
        query TestPagedNotesQuery($page: Int!, $authorId: ID!) {
          page(page: $page, perPage: 2) {
            pageInfo { hasNextPage currentPage }
            notes(authorId: $authorId) @paged(key: "TestPagedNotes_notes", page: $page) { id text }
          }
        }
        """)
    var pagedNotes: TestPagedNotesQuery

    @Query("""
        query TestPagedCharactersQuery($page: Int!) {
          page(page: $page, perPage: 2) {
            pageInfo { hasNextPage }
            characters @paged(key: "TestPagedCharacters_characters", page: $page) { id name }
          }
        }
        """)
    var pagedCharacters: TestPagedCharactersQuery

    @Fragment("""
        fragment TestFriends_character on Character {
          id
          friends(page: $page, perPage: 2) {
            pageInfo { hasNextPage }
            nodes @paged(key: "TestFriends_nodes", page: $page) { id name }
          }
        }
        """)
    var friends: TestFriends_character

    @Query("""
        query TestFriendsQuery($id: ID!, $page: Int!) {
          character(id: $id) { ...TestFriends_character }
        }
        """)
    var friendsQuery: TestFriendsQuery
}
