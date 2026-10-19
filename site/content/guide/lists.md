# Lists

A list that pages is a Relay connection, in a fragment of its own. The fragment owns the pagination. The store owns the merged pages. A mutation adds or removes an edge with a directive, and the view reads the list like any other field. This chapter is that fragment, what the store holds after each page, and the edge directives.

## The fragment that owns the list

Three directives make a connection. `@connection(key:)` names the list in the store. `@refetchable(queryName:)` gives the fragment a query of its own, which is how the next page is fetched. `@argumentDefinitions` declares the page size and the cursor as the fragment's arguments, so the screen's query need not know them.

{{host issue-list IssueList | The connection fragment, the row it spreads, and the screen that spreads it. The screen's query never mentions `first` or `after`.}}

The lens of a connection reads `nodes`, the records in order across every page, and also `hasNext`, `isLoadingNext`, and `pageInfo` with its cursors. `connectionID` is the key an edge directive names the list by. `loadNext(count)` fetches the next page with the fragment's query and its arguments. `refetch()` on the fragment's own lens fetches the first page again and replaces the list.

{{lens issue-list IssueList_repository | The connection as the compiler reported it. The paging surface is generated beside these accessors.}}

## What the store holds

The connection lives under its key in the store, apart from the pages. A page is a slot of its own under the field's storage key, `notes(first:2)`. The connection record under the key, `__TestNotes_notes_connection`, links the edges of every page in order. A refetch replaces the merged edges with the first page. A page fetched after a cursor that is no longer the connection's end is ignored.

{{script connections | The specification's connection script goes step by step: the first page, the second merged, a refetch that replaces, and an edge appended by a mutation. A page fetched after a cursor the connection has moved past is ignored by the merge, and it notifies nothing.}}

## Edge directives

A mutation that adds to or removes from a list says so on its payload. The store does the edit in the same batch as the payload's own records.

- `@appendEdge(connections:)` and `@prependEdge(connections:)` go on a payload field that is an edge.
- `@appendNode(connections:, edgeTypeName:)` and `@prependNode(connections:, edgeTypeName:)` go on a payload field that is a node.
- `@deleteEdge(connections:)` goes on a payload field holding the id of the node to remove from the lists.
- `@deleteRecord` goes on a payload field holding the id of a record to delete outright. Every list skips that record, and every link reads it as null.

The `connections` variable carries the connection ids the view read from its lenses, so the same mutation can add to one list or to three. Nothing edits the cache by hand, and nothing has to know which screens show the list.

{{host comments CommentComposer | A comment appended to the issue's comments. The composer takes the `connectionID` the list's lens read and passes it in `connections`.}}

{{script connections steps=4 | What `@appendEdge` leaves in the store is the new note's record, the new edge, and the connection's edge list one longer, with no refetch.}}

A payload with no id has no field for `@deleteRecord` to sit on, so `@deletes(type:, id:)` goes on the mutation and names the record by its type and the variable its key is passed as. The store deletes that record as `@deleteRecord` does, in the optimistic layer and in the server's commit.

## Lists paged by number

Some schemas have no cursors. AniList pages every list by number: `Page(page: 1, perPage: 50) { pageInfo { hasNextPage } media(...) }`, with one `pageInfo` for whichever list the page is asked for, and the lists on an entity, `Media.characters(page:, perPage:)`, page the same way. Baton does not pretend such a list is a connection. It says so with `@paged(key:, page:)`, on the list field, inside the field that takes the page:

```graphql
query SeasonQuery($page: Int!, $season: MediaSeason) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    media(season: $season, type: ANIME, sort: [POPULARITY_DESC])
      @paged(key: "SeasonQuery_media", page: $page) {
      id
      ...MediaCard_media
    }
  }
}
```

The pages merge into a record of their own in the store, under the list and its arguments, apart from the server's `Page(page: 1, perPage: 50)` record, which two lists may share. The first page replaces the merged list, the next appends, a page fetched again rewrites its elements in place. The lens over `Page` reads the merged `media`, and gains `hasNext`, which reads the merged `pageInfo.hasNextPage` and nothing else (AniList's `total` and `lastPage` are not to be trusted, and are not read), `isLoadingNext`, and `loadNext()`, which runs the screen's own query again with the next page number. No `@refetchable` fragment is needed; a refetch of the query replaces the list. The page variable is the operation's, declared `Int!`, and `pageInfo { hasNextPage }` is selected beside the list, or the compiler says what is missing.

{{script paged | The specification's paged script: the first page, the second merged, a second list under the same server page keeping its own flag, a page rewritten in place, a page past the end ignored, and a refetch that replaces.}}

A schema whose page info is not `pageInfo { hasNextPage }`, as the Rick and Morty API's `info { next }`, keeps reading one page per operation value: a screen with a page bar holds the current page's query, and the samples show one page at a time. [The decision](../../decisions/a-paged-list-merges-its-pages-by-number/) says what was chosen, what was not, and what would reopen it.

## Keys in a lazy list

Every lens carries its record's key, so a lazy list keys its items by that key. A row keeps its state while a refetch reorders the list.

```swift tab
ForEach(repository.issues.nodes) { issue in
    IssueRow(issue: issue.issueRow)
}
```

```kotlin tab
items(repository.issues.nodes, key = { it.recordID.key }) { issue ->
    IssueRow(issue.issueRow)
}
```

In Swift, `ForEach` takes a plural lens, a `Baton.List`, or a connection's `nodes`, through initializers Baton adds. They are keyed by the record, so no `id:` is needed.
