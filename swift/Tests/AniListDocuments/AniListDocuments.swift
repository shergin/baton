import Baton

/// The documents of the recording under `spec/anilist/`, compiled from the
/// schema AniList answered by introspection: one chunk of a user's list, an
/// entry by `MediaList(id:)`, which the lookup answers from the list's
/// records, and the save of one entry. `ListQuery` and its two fragments
/// are the text that asked for the recorded chunks.
@MainActor
public struct AniListDocuments {
    @Fragment("""
        fragment EntryRow_mediaList on MediaList {
          id
          status
          progress
          progressVolumes
          score
          repeat
          priority
          notes
          private
          hiddenFromStatusLists
          customLists(asArray: true)
          startedAt { year month day }
          completedAt { year month day }
          updatedAt
          media { id ...MediaCard_media }
        }
        """)
    var entryRow: EntryRow_mediaList

    @Fragment("""
        fragment MediaCard_media on Media {
          id
          idMal
          type
          format
          status(version: 2)
          episodes
          chapters
          volumes
          duration
          season
          seasonYear
          countryOfOrigin
          isAdult
          siteUrl
          title { romaji english native userPreferred }
          coverImage { large color }
          nextAiringEpisode { id episode airingAt }
        }
        """)
    var mediaCard: MediaCard_media

    @Query("""
        query ListQuery($userId: Int!, $mediaType: MediaType!, $chunk: Int!) {
          MediaListCollection(userId: $userId, type: $mediaType, chunk: $chunk, perChunk: 500, forceSingleCompletedList: true) {
            hasNextChunk
            lists {
              name
              isCustomList
              status
              entries { id ...EntryRow_mediaList }
            }
          }
        }
        """)
    var list: ListQuery

    @Query("""
        query EntryQuery($id: Int!) {
          MediaList(id: $id) { id ...EntryRow_mediaList }
        }
        """)
    var entry: EntryQuery

    @Mutation("""
        mutation SaveEntryMutation($id: Int, $progress: Int) {
          SaveMediaListEntry(id: $id, progress: $progress) { id ...EntryRow_mediaList }
        }
        """)
    var save: SaveEntryMutation.Action
}
