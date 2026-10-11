# Lists

A list that pages is a Relay connection in a fragment of its own. The fragment owns the pagination, the store owns the merged pages, a mutation adds or removes an edge with a directive, and the view reads the list like any other field. This chapter is that fragment, what the store holds after each page, and the edge directives.

## The fragment that owns the list

Three directives make a connection: `@connection(key:)` names the list in the store; `@refetchable(queryName:)` gives the fragment a query of its own, which the next page is fetched with; `@argumentDefinitions` declares the page size and the cursor as the fragment's arguments, so the screen's query need not know them.

{{host issue-list IssueList | The connection fragment, the row it spreads, and the screen that spreads it. The screen's query never mentions `first` or `after`.}}

The lens of a connection reads `nodes`, the records in order across every page; `hasNext` and `isLoadingNext`; `pageInfo` with its cursors; `connectionID`, the key an edge directive names the list by; and `loadNext(count)`, which fetches the next page with the fragment's query and the lens's own arguments, and `refetch()`, which fetches the first page again.

{{lens issue-list IssueList_repository | The connection as the compiler reported it. The paging surface is generated beside these accessors.}}

## What the store holds

The connection lives under its key in the store, apart from the pages: a page is a slot of its own under the field's storage key, `notes(first:2)`, and the connection record under the key, `__TestNotes_notes_connection`, links the edges of every page in order. A refetch replaces the merged edges with the first page; a page already seen is a commit that changes nothing.

{{script connections | The specification's connection script, step by step: the first page, the second merged, a refetch that replaces, an edge appended by a mutation, and a page committed again that notifies nothing.}}

## Edge directives

A mutation that adds to or removes from a list says so on its payload, and the store does the edit in the same batch as the payload's own records:

- `@appendEdge(connections:)` and `@prependEdge(connections:)` on a payload field that is an edge;
- `@appendNode(connections:, edgeTypeName:)` and `@prependNode(connections:, edgeTypeName:)` on a payload field that is a node;
- `@deleteEdge(connections:)` on a payload field holding the id of the node to remove from the lists;
- `@deleteRecord` on a payload field holding the id of a record to delete outright, which every list skips and every link reads as null.

The `connections` variable carries the connection ids the view read from its lenses, so the same mutation can add to one list or three. Nothing edits the cache by hand, and nothing has to know which screens show the list.

{{host comments Comments.swift | A comment appended to the issue's comments. The composer takes the `connectionID` the list's lens read and passes it in `connections`.}}

{{script connections steps=4 | What `@appendEdge` leaves in the store: the new note's record, the new edge, and the connection's edge list one longer, with no refetch.}}

## Page-based lists

The Rick and Morty API pages by number, `characters(page: 2)`, which is not a connection, and Baton does not pretend it is one: each page is a query of its own with the page as a variable, and the store keeps each under its storage key. A screen that shows twenty rows per page holds the current page's query; a screen that wants an endless list over such an API composes it from the pages, as the sample does. Page-based pagination as a concept of its own is on the watch list, with the trigger that would promote it; [What earns a concept](../../principles/what-earns-a-concept/) is why it is not a thirteenth word.

## Keys in a lazy list

Every lens carries its record's key, so a lazy list keys its items by it and a row keeps its state while a refetch reorders the list:

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

In Swift a `Baton.List` is a `RandomAccessCollection` of lenses identifiable by record, so `ForEach` takes it as it is.
