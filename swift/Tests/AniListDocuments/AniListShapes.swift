import Baton

/// Documents over the shapes of AniList's schema the recorded list does not
/// reach, which the compiler's second set of goldens pins: a root field
/// spelled like its type with enums that grow behind a `version` argument,
/// a page of media by number, the viewer, the twenty-member union of
/// notifications with no interface, a delete whose payload names no record,
/// and fields of the `Json` scalar.
@MainActor
public struct AniListShapes {
    @Query("""
        query MediaQuery($id: Int!) {
          Media(id: $id) {
            id
            ...MediaCard_media
            statusV1: status
            source(version: 3)
            relations {
              edges {
                id
                relationType(version: 2)
                node { id title { romaji } }
              }
            }
          }
        }
        """)
    var media: MediaQuery

    @Query("""
        query SeasonQuery($season: MediaSeason!, $seasonYear: Int!, $page: Int!) {
          Page(page: $page, perPage: 48) {
            pageInfo { hasNextPage }
            media(season: $season, seasonYear: $seasonYear, type: ANIME, sort: [POPULARITY_DESC]) {
              id
              ...MediaCard_media
            }
          }
        }
        """)
    var season: SeasonQuery

    @Query("""
        query ViewerQuery {
          Viewer {
            id
            name
            avatar { large }
            unreadNotificationCount
            mediaListOptions {
              scoreFormat
              animeList { customLists advancedScoringEnabled }
            }
          }
        }
        """)
    var viewer: ViewerQuery

    @Query("""
        query NotificationsQuery($page: Int!) {
          Page(page: $page, perPage: 25) {
            notifications {
              __typename
              ... on AiringNotification { id episode contexts media { id title { romaji } } }
              ... on FollowingNotification { id user { id name } }
              ... on ActivityLikeNotification { id activityId user { id name } }
              ... on ThreadCommentReplyNotification { id commentId }
              ... on MediaDataChangeNotification { id mediaId reason }
            }
          }
        }
        """)
    var notifications: NotificationsQuery

    @Query("""
        query ThreadCommentsQuery($threadId: Int!) {
          Page(page: 1, perPage: 25) {
            threadComments(threadId: $threadId) { id comment childComments }
          }
        }
        """)
    var threadComments: ThreadCommentsQuery

    @Query("""
        query EntryScoresQuery($id: Int!) {
          MediaList(id: $id) { id score advancedScores customLists(asArray: true) }
        }
        """)
    var entryScores: EntryScoresQuery

    @Mutation("""
        mutation DeleteEntryMutation($id: Int!) @deletes(type: "MediaList", id: $id) {
          DeleteMediaListEntry(id: $id) { deleted }
        }
        """)
    var delete: DeleteEntryMutation.Action
}
