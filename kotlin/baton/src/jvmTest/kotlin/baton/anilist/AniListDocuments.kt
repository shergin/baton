package baton.anilist

import baton.Fragment
import baton.Mutation
import baton.Query

/**
 * The documents of the recording under `spec/anilist/`, compiled from the
 * schema AniList answered by introspection: one chunk of a user's list, an
 * entry by `MediaList(id:)`, which the lookup answers from the list's
 * records, and the save of one entry. The same text as
 * `swift/Tests/AniListDocuments/AniListDocuments.swift`; `ListQuery` and its
 * two fragments are the text that asked for the recorded chunks.
 */
@Fragment(
    """
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
    """,
)
@Fragment(
    """
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
    """,
)
@Query(
    $$"""
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
    """,
)
@Query(
    $$"""
    query EntryQuery($id: Int!) {
      MediaList(id: $id) { id ...EntryRow_mediaList }
    }
    """,
)
@Mutation(
    $$"""
    mutation SaveEntryMutation($id: Int, $progress: Int) {
      SaveMediaListEntry(id: $id, progress: $progress) { id ...EntryRow_mediaList }
    }
    """,
)
object AniListDocuments
