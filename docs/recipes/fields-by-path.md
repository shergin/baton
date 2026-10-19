# Fields a server nulls by path

A normalized store keeps one slot per field of a record, for each set of
arguments, whichever operation wrote it. Baton's store writes what
arrives, because [the response is the oracle](../principles/response-is-the-oracle.md).
So when a server answers the same field differently by the path that
reached the record, the later response wins. Suppose a browse page answers
a media's `voiceActors` as null, and the detail screen fetched them a
minute before. The page writes null over them, and the detail shows none.
No error is raised. A null in a nullable field is data, and the store
cannot tell a null the path produced from a null the record has. Nothing
heals it either, because only missing data is healed, and a null is not
missing.

This was reported for AniList on
[#52](https://github.com/shergin/baton/issues/52): `CharacterEdge.voiceActors`
null under `Page.media`, and filled under the root `Media(id:)`. On
2026-10-18 an anonymous request got it filled on both paths, for pages of
one to fifty media. Whether a server nulls a field by path can depend on
the viewer, on the size of the request, or on the server's release, and
the schema says nothing of it. So the convention below does not depend on
catching it. It lives in the documents.

## The convention

- **A list fragment selects the record's identity and the row's own
  fields.** These are scalars of the record, and small objects with no list
  beneath them, such as a title or a cover. They read the same on every
  path that reaches the record.
- **Path-dependent fields are selected in the detail operation only.**
  These are the lists and connections nested under a row (characters,
  staff, relations, and the voice actors under the characters), and any
  field the server fills only at its root. The detail's path fills them,
  and no list response writes their slots.
- **Viewer-dependent fields are kept out of list fragments too.** On
  AniList these are `mediaListEntry`, `isFavourite` and
  `title.userPreferred`. One environment is one identity
  ([the session](../decisions/the-environment-is-the-session.md)), so every
  request in it asks as the same viewer. Such a field is path-dependent
  only if the server makes it so. Each of these still has a better place:
  - `title.userPreferred` follows a setting of the viewer's. When the
    setting changes, the response to the settings mutation carries the
    viewer's options and names no media. Every stored `userPreferred` keeps
    the old language until each operation that selected it is fetched
    again. Read `title { romaji english native }` in the row instead, and
    choose on the client by the viewer's `options { titleLanguage }`. The
    settings mutation's response then re-renders every row.
  - `mediaListEntry` and `isFavourite` are the viewer's state, which the
    viewer's own mutations change. Select them where the viewer changes
    them, in the detail, and in the payload of the mutation that changes
    them, so that its response writes the slot the detail reads.

Arguments are part of a field's storage key. `voiceActors(language:
JAPANESE)` and `voiceActors(language: ENGLISH)` are two slots. Only the
same field, with the same arguments, on the same record, is written by
both paths.

## The documents

The row's fragment, and the browse page that spreads it beside the
viewer's title language:

```graphql
fragment MediaRow_media on Media {
  id
  format
  episodes
  seasonYear
  coverImage { medium }
  title { romaji english native }
}

query BrowseQuery($page: Int!) {
  Viewer { id options { titleLanguage } }
  Page(page: $page, perPage: 50) {
    media(type: ANIME, sort: POPULARITY_DESC) { id ...MediaRow_media }
  }
}
```

The detail spreads the same row, and adds what only its path should
write:

```graphql
query MediaQuery($id: Int!) {
  Media(id: $id) {
    id
    ...MediaRow_media
    isFavourite
    mediaListEntry { id status progress }
    characters(sort: [ROLE, RELEVANCE], perPage: 25) {
      edges {
        role
        node { id name { full } }
        voiceActors(language: JAPANESE) { id name { full } }
      }
    }
  }
}
```

In Swift the fragment sits in `@Fragment` on the row's view, and the
queries in `@Query` on the screens. In Kotlin they sit on the composables,
and the queries are written as `$$"""` strings because of their
variables. The text is the same.

The title is chosen on the client, from the fields the row reads. In
Swift:

```swift
extension UserTitleLanguage {
    /// The media's title in this language, from the titles the row reads.
    @MainActor
    func title(of media: MediaRow_media) -> String {
        let romaji = media.title?.romaji ?? ""
        switch self {
        case .ENGLISH, .ENGLISH_STYLISED: return media.title?.english ?? romaji
        case .NATIVE, .NATIVE_STYLISED: return media.title?.native ?? romaji
        default: return romaji
        }
    }
}
```

And in Kotlin:

```kotlin
/** The media's title in this language, from the titles the row reads. */
fun UserTitleLanguage.title(media: MediaRow_media): String {
    val romaji = media.title?.romaji.orEmpty()
    return when (this) {
        UserTitleLanguage.ENGLISH, UserTitleLanguage.ENGLISH_STYLISED -> media.title?.english ?: romaji
        UserTitleLanguage.NATIVE, UserTitleLanguage.NATIVE_STYLISED -> media.title?.native ?: romaji
        else -> romaji
    }
}
```

The browse screen passes `data.Viewer?.options?.titleLanguage` to each
row, so the screen's body reads the viewer's setting, and a response that
changes it re-renders the rows.

## Telling the two apart

The schema types a field the same way on every path, so it cannot say.
Three places can, in this order:

1. **The field's description.** Some schemas say where a field is
   filled.
2. **A probe.** Send one request, as the viewer, that reaches one record
   by both paths, in the shape the list really uses, and compare the two
   halves of the raw response. Send it with any HTTP client, not through
   the store: through the store, both halves would write one record, and
   the later would win.

   ```graphql
   query ProbeVoiceActors($id: Int!) {
     page: Page(perPage: 50) {
       media(id: $id) { id characters(perPage: 3) { edges { voiceActors(language: JAPANESE) { id } } } }
     }
     root: Media(id: $id) { id characters(perPage: 3) { edges { voiceActors(language: JAPANESE) { id } } } }
   }
   ```

3. **The default.** Without either, treat a list nested under a page's
   rows as path-dependent, and a record's own scalar as not. That is what
   the convention does, so it is safe whichever way the server answers
   today.

A probe is evidence about one release of a server, on one date. Keep the
convention after a probe passes.

The documents and the code on this page were compiled in both runtimes
against AniList's schema on 2026-10-18.
