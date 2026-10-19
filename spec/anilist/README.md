# AniList

A user's list recorded from AniList's public API, `https://graphql.anilist.co`,
with the schema the API answered by introspection. The responses are the
server's bytes, frozen like the rest of `spec/`; the documents that asked for
them are `swift/Tests/AniListDocuments/AniListDocuments.swift`, and the same
text is the Kotlin host `kotlin/baton/src/jvmTest/kotlin/baton/anilist/AniListDocuments.kt`.
`ListQuery` there names its type variable `$mediaType` where the request
that was recorded named it `$type`, since every Kotlin operation has a
`type` and the Kotlin emitter refuses the clash; a variable's name does not
reach the response. The Swift target `BatonAniListTests` and the Kotlin harness's
`jvmAniListTest` prove the recording against one dump, and the bench suites
measure it.

- `schema.graphql`: the SDL printed from the standard introspection query,
  sent once without a token on 2026-10-19 at 01:59 UTC, types sorted by
  name as graphql-js's `printSchema` orders them, with descriptions and
  deprecations; 183 types, 3 unions, no interfaces. Its MD5 is
  `64c79d9bee49eec0fb16214f1f7b77c0`.
- `list-anime-chunk-1.json`, `list-anime-chunk-2.json`: `ListQuery` with
  `type: ANIME` and `chunk: 1` and `2`, `perChunk: 500`, 500 entries each,
  each with its media; recorded on 2026-10-18 between 21:50 and 21:54 UTC
  from a public list, read without a token. AniList fills chunks in the
  order of the entries' ids, so these are the list's oldest thousand
  entries, and `hasNextChunk` is true in both.
- `list-anime.store.json`: the store after both chunks, committed in
  order.
- `save-entry-991-progress.json`: `SaveEntryMutation`'s response shaped by
  hand, since the mutation needs a signed-in user: entry 991 as chunk 2
  holds it, byte for byte, with `progress` 249 where the list says 248. The
  server would also move `updatedAt`; this payload changes the one field.

The recording is anonymized, and nothing else in it was edited. The
responses carry no user name; the user's id, which the request named, is 0
in every variable here, an id no AniList user has. The entries' ids are
renumbered from 1 in the order the chunks list them, since an entry's id
names its user through the public API. The 269 notes the user wrote are
`Note 1.` to `Note 269.` in the same order. Media, titles, images and
airing times are AniList's catalog and stay as the server wrote them, with
its escaped slashes and `\u` escapes.

The shapes the recording holds that the other fixtures do not: identity by
`id: Int!` per type, so `Media:1` and `MediaList:1` are two records; an
enum argument in a storage key, `status(version: 2)`; a `Json` scalar,
`customLists`, null throughout; a root field spelled like its type,
`MediaListCollection`; and one response of 500 entries, where the other
fixtures' lists are pages of 50 or less. An entry is six records, itself,
its media, the media's title and cover, and the entry's two dates, and a
seventh for a show still airing: after both chunks the store holds 6,014
records.
