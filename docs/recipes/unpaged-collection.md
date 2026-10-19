# An unpaged collection into the image

Some servers answer a whole collection in one request rather than page by
page. AniList's `MediaListCollection` is one: a user's whole anime or
manga list, up to five hundred entries a chunk, in `lists` grouped by
status and by custom list. The groups have no ids. Each group's `entries`
are `MediaList` records, which do have ids. Against a rationed API (see
[the budgeted transport](budgeted-transport.md)), one request for the
list is far better than a page at a time.

The pattern has three parts: one operation with a long expiration, a
grouping made on the client from each entry's own fields, and the image,
which carries the list to the next launch. It sits beside
[discover once](discover-once.md), the other pattern for data a screen
cannot page.

## One operation, kept for an hour

```graphql
query ListQuery($userId: Int!, $mediaType: MediaType!) @cacheExpiration(seconds: 3600) {
  MediaListCollection(userId: $userId, type: $mediaType, perChunk: 500, chunk: 1, forceSingleCompletedList: true) {
    hasNextChunk
    lists { entries { id ...EntryRow_mediaList } }
  }
}
```

`@cacheExpiration(seconds:)` states how old the list may be before it
reads as stale. A user's list changes when the user edits it, and those
edits are this app's own mutations, whose responses write the entries.
Only an edit made elsewhere, on the website or another device, waits
for the expiration, or for a `refetch()` when the user pulls to refresh,
or for `revalidate()` when the app returns to the foreground.

A list past five hundred entries answers `hasNextChunk`. The next chunk is
another operation value, `chunk: 2`, with its own root, and the grouping
reads the entries of every chunk the app holds.

## Group on the client, from each entry's own fields

The groups the server sends are records without ids, stored under the
operation's root by their path. A mutation's response,
`SaveMediaListEntry`'s `MediaList`, writes the entry's record and leaves
every group's array as it was. A screen that read the server's groups
would keep a row under its old heading until the list is fetched again,
or it would need an updater to move the row from one array to another.

Read each entry's own fields instead: its `status`, unless
`hiddenFromStatusLists` is set, and the custom lists it is in, which is
the `customLists` of [a `Json` scalar read as a value](json-scalar.md).
The body that groups reads those fields, so the commit that changes one
runs the body again, and the row is under its new heading in that same
turn. With an optimistic response, that is the turn of the call. No
updater is written.

The row's fragment, with the mutation that moves it:

```graphql
fragment EntryRow_mediaList on MediaList {
  id
  status
  progress
  hiddenFromStatusLists
  customLists(asArray: true)
  media { id episodes title { romaji } }
}

mutation EntryRowSave($id: Int, $status: MediaListStatus) {
  SaveMediaListEntry(id: $id, status: $status) { id ...EntryRow_mediaList }
}
```

The server repeats an entry under every group it is in: under its
status, and again under each custom list it is in. So the grouping reads
each entry once, and the groups themselves are read only as a bag of
entries. In Swift:

```swift
/// The shelves of the list, from each entry's own fields: its status,
/// unless it is hidden from the status lists, and each custom list it is
/// in. The server repeats an entry under every group it is in, so an entry
/// is read once, and the groups themselves are not read.
@MainActor
func shelves(_ data: ListQuery.Data) -> [(name: String, entries: [EntryRow_mediaList])] {
    var byStatus: [MediaListStatus: [EntryRow_mediaList]] = [:]
    var byList: [String: [EntryRow_mediaList]] = [:]
    var seen: Set<Int> = []
    for group in data.MediaListCollection?.lists ?? .empty {
        for entry in group.entries ?? .empty where seen.insert(entry.id).inserted {
            let row = entry.entryRow
            if let status = row.status, row.hiddenFromStatusLists != true {
                byStatus[status, default: []].append(row)
            }
            for name in row.customLists?.names ?? [] {
                byList[name, default: []].append(row)
            }
        }
    }
    let order: [MediaListStatus] = [.CURRENT, .REPEATING, .PAUSED, .PLANNING, .COMPLETED, .DROPPED]
    return order.compactMap { status in byStatus[status].map { (status.scalarText.capitalized, $0) } }
        + byList.keys.sorted().map { ($0, byList[$0] ?? []) }
}

/// The list under its shelves, each row once per shelf it sits on.
struct Shelves: View {
    let data: ListQuery.Data

    var body: some View {
        List {
            ForEach(shelves(data), id: \.name) { shelf in
                Section(shelf.name) {
                    ForEach(shelf.entries, id: \.id) { EntryRow(entry: $0) }
                }
            }
        }
    }
}
```

And in Kotlin, where a row's key names its shelf, since one entry may sit
on two:

```kotlin
/**
 * The shelves of the list, from each entry's own fields: its status,
 * unless it is hidden from the status lists, and each custom list it is
 * in. The server repeats an entry under every group it is in, so an entry
 * is read once, and the groups themselves are not read.
 */
fun shelves(data: ListQuery.Data): List<Pair<String, List<EntryRow_mediaList>>> {
    val byStatus = mutableMapOf<MediaListStatus, MutableList<EntryRow_mediaList>>()
    val byList = mutableMapOf<String, MutableList<EntryRow_mediaList>>()
    val seen = mutableSetOf<Int>()
    for (group in data.MediaListCollection?.lists.orEmpty()) {
        for (entry in group.entries.orEmpty()) {
            if (!seen.add(entry.id)) continue
            val row = entry.entryRow
            val status = row.status
            if (status != null && row.hiddenFromStatusLists != true) byStatus.getOrPut(status) { mutableListOf() }.add(row)
            for (name in row.customLists?.names.orEmpty()) byList.getOrPut(name) { mutableListOf() }.add(row)
        }
    }
    val order = listOf(MediaListStatus.CURRENT, MediaListStatus.REPEATING, MediaListStatus.PAUSED, MediaListStatus.PLANNING, MediaListStatus.COMPLETED, MediaListStatus.DROPPED)
    return order.mapNotNull { status -> byStatus[status]?.let { status.scalarText.lowercase().replaceFirstChar(Char::titlecase) to it } } +
        byList.keys.sorted().map { it to byList.getValue(it) }
}

/** The list under its shelves, each row once per shelf it sits on. */
@Composable
fun Shelves(data: ListQuery.Data) {
    LazyColumn {
        for ((name, entries) in shelves(data)) {
            item(key = name) { Text(name, style = MaterialTheme.typography.titleSmall) }
            items(entries, key = { "$name/${it.id}" }) { EntryRow(it) }
        }
    }
}
```

The grouping reads every entry's `customLists`, which a mapped scalar
converts at each read, so a list of five hundred costs five hundred small
decodes each time `shelves` runs. The body runs it when a field it read
changes, and also when the view is rendered again for reasons of its own.
A model that keeps the shelves, as
[derived state outside views](derived-state.md) keeps a count, runs it
only when a field it read changes, and the view reads the result. For a
list of several chunks, [a derivation over a whole operation](derived-state.md#a-derivation-over-a-whole-operation)
keeps one stream a chunk, takes the first reading untracked at launch,
and says what a tracked pass of the list costs.

Two edits still change the server's arrays rather than an entry's fields:

- **An entry the list does not hold yet**, added with
  `SaveMediaListEntry(mediaId:)`, is in no group's array. Fetch the list
  again after that mutation. It is one request.
- **A deleted entry** leaves every shelf at once. A mutation that names
  the record it deletes, with `@deletes(type: "MediaList", id: $id)` over
  `DeleteMediaListEntry(id: $id) { deleted }`, deletes it in the turn of
  the call, and a list of records skips a deleted record.

## The image carries it

With persistence, the list's records and the time it was fetched are
written to the image. At the next launch the screen's `@Query` attaches
with the default policy, `storeOrNetwork`. The store answers from the
image, and the list is within its hour, so the attach sends no request.
Past the hour the list still shows from the image, and the handle fetches
behind it, with `isRefreshing` set until the response commits. The age
survives the launch because the image keeps when each operation was
fetched.

The screen reads the phase and the fetch, as every screen does:

```swift
/// The whole list in one request, kept for an hour, and carried by the
/// image to the next launch.
struct ListScreen: View {
    @Query("""
        query ListQuery($userId: Int!, $mediaType: MediaType!) @cacheExpiration(seconds: 3600) {
          MediaListCollection(userId: $userId, type: $mediaType, perChunk: 500, chunk: 1, forceSingleCompletedList: true) {
            hasNextChunk
            lists { entries { id ...EntryRow_mediaList } }
          }
        }
        """)
    var list: ListQuery

    var body: some View {
        switch list.phase {
        case .loading:
            ProgressView()
        case .ready(let data):
            Shelves(data: data)
                .safeAreaInset(edge: .top) {
                    if list.fetch.failure?.error is Outage { OutageNote() }
                }
        case .failed(is Outage):
            OutageNote()
        case .failed(let error):
            ContentUnavailableView("No list", systemImage: "list.bullet", description: Text(error.localizedDescription))
        }
    }
}
```

```kotlin
/** The whole list in one request, kept for an hour, and carried by the image to the next launch. */
@Query(
    $$"""
    query ListQuery($userId: Int!, $mediaType: MediaType!) @cacheExpiration(seconds: 3600) {
      MediaListCollection(userId: $userId, type: $mediaType, perChunk: 500, chunk: 1, forceSingleCompletedList: true) {
        hasNextChunk
        lists { entries { id ...EntryRow_mediaList } }
      }
    }
    """,
)
@Composable
fun ListScreen(userId: Int) {
    val list = rememberQuery(ListQuery(userId = userId, mediaType = MediaType.ANIME))
    when (val phase = list.phase) {
        Phase.Loading -> CircularProgressIndicator()
        is Phase.Ready -> Column {
            if (list.fetch.failure?.error is Outage) OutageNote()
            Shelves(phase.data)
        }
        is Phase.Failed -> if (phase.error is Outage) OutageNote() else Text(phase.error.message.orEmpty())
    }
}
```

`Outage` is the error of [the budgeted transport](budgeted-transport.md),
read beside the data. The variable is `$mediaType` and not `$type`,
because a variable named `type` clashes with the operation's own `type` in
the generated Kotlin, and the compiler says so.

## Why not a connection

A connection is the server's pages merged into one client record, and it
needs a server that pages. This one answers the whole list, so there is
nothing to merge, and the groups would be one more structure to keep in
step with the entries. The entries' own fields are the truth the server
keeps, and the grouping is a view of them.

The documents and the code on this page were compiled in both runtimes
against AniList's schema on 2026-10-18.
