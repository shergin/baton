# A list paged by number merges its pages under `@paged`

Status: accepted, 2026-10-18; answers
[#49](https://github.com/shergin/baton/issues/49). Serves
[What earns a concept](../principles/what-earns-a-concept.md),
[Relay's words](../principles/relays-words.md) and
[The store is the UI's state](../principles/store-is-the-ui-state.md).
Reopen if Relay or the GraphQL specification gains a word for a list paged
by number, which then replaces ours; if a real schema pages by offset,
which adds `offset:` beside `page:` with the next position being the last
page's plus its length, not a second mechanism; if a real screen pages a
schema whose page info is not `pageInfo { hasNextPage }`, as the Rick and
Morty API's `info { next }` is not, which adds a second reading of the flag;
if a real write must insert into or remove from a paged list, which brings
the edge directives to the paged key; or if a server pages a list under a
storage key that does not change with the page.

## Context

Relay's `@connection` is the cursor connections specification: `edges`,
`pageInfo` with `endCursor` and `hasNextPage`, a page fetched `after` a
cursor appended to the one before. AniList has none of it. Every list is
`Page(page: Int, perPage: Int)` with eighteen list fields and one
`pageInfo`, and the lists on an entity, `Media.characters(page:, perPage:)`,
borrow `edges`, `nodes` and `pageInfo` but page by number. Of the page
info the API's documentation and its lead developer trust `hasNextPage`
alone: `total` came back as 5000 for two unrelated queries, and `lastPage`
is derived from it. The issue is the owner's own app, Yakitate, where
number-paged lists are every list: the season, the search, the browse
with its filters, and on each media page its characters, staff, reviews,
recommendations and airing schedule.

The watch list held "a directive for page- and offset-based pagination"
with the trigger "a second real schema without cursor connections". The
sample API in `spec/` (`characters(page:)`) was the first; AniList is the
second. The terminology's **Page** entry said such a list is composed in
the UI from plain operations until the watch list promotes a directive.

The composition was built first, and it taught the key. Two operations
paged two list fields under the same container, `Page(page: $page,
perPage: 50) { pageInfo { hasNextPage } airingSchedules(...) }` and
`Page(page: $page, perPage: 50) { pageInfo { hasNextPage } media(...) }`.
`Page` has no identity, so the store keys it by its path and arguments,
and both operations' first pages are one record,
`client:root:Page(page:1,perPage:50)`. The two lists sit in it under their
own storage keys, but `pageInfo` is one slot: after the season's page 1
committed `hasNextPage: true`, the week's empty page 1 read `true` too, and
the app asked for two pages it did not need against a budget of thirty
requests a minute. The app gave each list family its own `perPage`, which
works and is a smell. The merged list, and its page info, belong to the
list field, not to the wrapper the server puts around it.

## Decision

A list paged by number says so with a directive of Baton's own, on the
list field, inside the field that takes the page:

```graphql
query SeasonQuery($page: Int!, $season: MediaSeason, $seasonYear: Int) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    media(season: $season, seasonYear: $seasonYear, type: ANIME, sort: [POPULARITY_DESC])
      @paged(key: "SeasonQuery_media", page: $page) {
      id
      ...MediaCard_media
    }
  }
}

fragment MediaCharacters_media on Media {
  characters(sort: [ROLE], page: $page, perPage: 25) {
    pageInfo { hasNextPage }
    edges @paged(key: "MediaCharacters_edges", page: $page) { role node { id name } }
  }
}
```

- **Where it sits.** On a field whose value is a list of records, in the
  selection of the field that passes the page variable in an argument,
  its *container*: `Page` here, `characters` there. The directive names the
  page variable itself, since on this schema the page is the container's
  argument, not the list's. `key` is a string ending in `_` and the list
  field's name or alias, as Relay's `@connection` key does. `page` is a
  variable of the operation, declared `Int!` or `Int` with a default that
  is not null, so every run names its page, and not a fragment argument,
  since `loadNext()` advances it on the operation. The container selects
  `pageInfo { hasNextPage }` beside the list, Relay's `PageInfo` word,
  which the merged page info is copied from. A directive elsewhere, a
  constant page, a scalar list, a fragment argument, a key of another
  shape, a container that does not take the variable or does not select
  the page info, is an error at the directive's position in the host file.
- **The record.** The pages merge into a client record of the container's
  type, hanging off the container's parent, the first record above the
  list whose key does not read the page variable: the root for
  `Query.Page`, the `Media` entity for `Media.characters`. Its key is the
  parent's, `:`, and `__<key>_paged` with the arguments of the container
  except the one that reads the page and the arguments of the list field,
  sorted by name and rendered from the variables:
  `client:root:__SeasonQuery_media_paged(perPage:50,season:"WINTER",seasonYear:2026,sort:["POPULARITY_DESC"],type:"ANIME")`,
  `Media:1:__MediaCharacters_edges_paged(perPage:25,sort:["ROLE"])`. Two
  lists under one wrapper never share it, two seasons of one list never
  share it, and two page sizes never share it. Its page info is its own
  record, `<key>:pageInfo`. The lens reads the container through this key,
  as a connection is read through Relay's handle key; the server's page
  stays under its own key beside it.
- **The merge.** A page is an edit of the commit that wrote it, in the same
  batch. The list's first page replaces the merged list; the page after the
  last merged appends; a page already merged rewrites its own elements in
  place; any other page is ignored, as a connection page after a cursor
  that is no longer the end is ignored. The first page is the one the list
  started with, so a schema that counts from zero needs no setting. The
  merged list references the pages' element records, as a connection
  references its pages' edges
  ([the decision](connections-own-their-edges.md)), in order, each record
  once, null elements dropped. The fields the operation selected of the
  container follow the page's, except the list and the page info link, so
  a page record two lists share lends the other list nothing; the page
  info's selected fields follow the page's when the page replaces or is
  the last merged; a page rewritten in the middle leaves them. The record keeps where it stands as client fields: `__firstPage`,
  `__pageLengths` with the span of each page in the merged list, and
  `__isLoadingNext`.
- **What the lens reads.** The container's lens gains `hasNext`,
  `isLoadingNext` and `loadNext()`. `hasNext` reads the merged page info's
  `hasNextPage` and nothing else: not `total`, `lastPage`, `currentPage` or
  a count. `isLoadingNext` is a client field on the record, set as a local
  write for the fetch's duration, as a connection's is. The list itself
  reads through the field's own accessor, with the merged elements.
- **`loadNext()`.** Runs the operation that owns the lens with the owner's
  variables and the page variable set to the page after the last merged.
  The fetch has no handle and no root of its own: the root it makes is
  dated and waits in the release buffer as a refetch's does, and the
  client record owns the pages. A no-op while a page loads or when
  `hasNext` is false; a lens made by hand, with no environment, throws as a
  connection's does. No fragment need be `@refetchable`, which Relay's
  front end could not grant a fragment on `Media` here, since the schema
  has no `Node` and no `node(id:)`.
- **Refresh.** A refetch of the owner fetches its own page again, the
  first, and replaces the merged list, as a cursorless connection fetch
  replaces one. An expiration does the same through the owner's
  revalidation. A page in the middle fetched again by hand rewrites its
  elements in place.
- **Not Relay's, so declared as Baton's.** The directive is declared in the
  schema extension the compiler adds, as `@cacheExpiration` is, so Relay's
  front end checks its arguments and its text transforms leave it out of
  the text a server receives; the lowering reads it from the field and
  checks what it names. It is the third directive that is not Relay's. As
  it is being built, the plan JSON carries `"paged"` on the container field
  with the key, the client storage key, the list's storage key, the page
  info's type and the page variable, and the generated-code format rises to
  21 in Swift and 5 in Kotlin.

## Evidence

- AniList, measured against `https://graphql.anilist.co` on 2026-10-18 and
  recorded on the issue: `Page(page, perPage)` with eighteen list fields
  and one `pageInfo { total perPage currentPage lastPage hasNextPage }`;
  `Media.characters(sort:, role:, page:, perPage:) { edges nodes pageInfo }`
  and the other lists on an entity; `perPage` capped at 50 silently; no
  cursor anywhere; no `Node`, no `node(id:)`; `total` and `lastPage`
  documented as inaccurate and confirmed so by the lead developer on
  2026-03-19.
- The owner's composition, 2026-10-18: the shared `pageInfo` slot on
  `Query.Page(page:1,perPage:50)` read another list's flag and cost three
  requests of a budget of thirty a minute. The key is the list field's,
  not the container's.
- Relay v21.0.1, the revision the compiler pins, read 2026-10-18.
  `@connection` is the cursor specification: the transform reads `first`
  and `after` or `last` and `before`
  (`compiler/crates/relay-transforms/src/connections/connection_util.rs`,
  lines 92-115) and requires `edges` and `pageInfo` with the cursors, and
  its handler merges by `endCursor` and `startCursor`
  (`packages/relay-runtime/handlers/connection/ConnectionHandler.js`).
  The client record hangs off the field under the handle key
  (`getRelayHandleKey(CONNECTION, key, null)`, line 288), which is the
  shape kept here: a client record on the parent, keyed by the field, with
  its own page info.
- The GraphQL specification has no pagination; the Relay cursor
  connections specification has cursors only. A page number is a schema
  convention older than both, which is why the word is Baton's.
- Baton as built: a connection's merge is an edit of the commit over a
  client record the resolution keys per variables, and a page's loading
  flag is a client field written locally; `Environment.paginate` sets it
  around a fetch by type and variables. The paged list is that machinery
  with a merge mode by page number beside the cursor modes.
- The watch list's trigger was met by the second real schema, and the
  composition ran first, as the principle asks: the directive expresses
  what the composition could not say to the lens, the merged list and its
  own flag.
- Nothing new is measured: a page costs the connection merge's work, one
  list write and one page info copy per page, and the lens reads the same
  slots a connection lens reads.

## Not chosen

- `@connection` with a page argument: Relay's word, and Relay's meaning is
  the cursor specification, which `validate_connections` enforces; a page
  number would be a second meaning under one word.
- The directive on the container, with the list named by a string, or the
  merged list keyed by the container: the owner's evidence is that the
  container is shared and the key is the list's; a key of the container's
  arguments alone would merge two seasons of one list into one record and
  two lists of one wrapper into one page info.
- Reading `total`, `lastPage`, `currentPage`, a count or the next page's
  number for `hasNext`, or a setting that names which field says it: the
  one field AniList's own documentation trusts is Relay's word, and a
  second reading of the flag waits for a real screen that needs it. The
  Rick and Morty API's `info { next }` is such a shape, and its lists keep
  reading one page per operation value, as the sample shows them.
- Offsets now: no real schema asks, and the arithmetic differs (the next
  position is the last page's plus its length); the directive takes an
  `offset:` argument beside `page:` when one does.
- `hasPrevious` and `loadPrevious()`: a list paged by number starts at its
  first page, and a screen that starts elsewhere shows one page at a time
  through its own operation value.
- Edge directives into a paged list: no real write asks; a record of the
  container's type is not a connection, and an edit naming its key leaves
  it alone until one does.
- Copying the elements into records the list owns, as Relay copies edges:
  the elements are the entities and the pages' edge records, which the
  merged list reaches by reference, as the connections decision found for
  edges.
- Adding `pageInfo { hasNextPage }` to the selection when the author left
  it out, as Relay's connection transform adds the cursors: a lens reads
  what its author selected.
- Composing in the UI, the status quo: a page holder per list, the
  concatenation and the flag in the view, and a refresh that cannot reach
  the lens; the owner built it and reported what it taught.
