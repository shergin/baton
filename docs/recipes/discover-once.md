# Discover once, refresh through `nodes(ids:)`

An app whose subjects arrive by natural key, a repository's owner and name
and an issue's number from a notification, cannot ask for them in one
operation: operations are fixed at build time, and the count of aliases
cannot vary. The pattern every such app settles on has two halves, and the
Swift GitHub sample shows both.

## Discover once, by natural key

The first time a subject is seen, one operation looks it up by the key the
app has, and the response carries the node's `id`:

```graphql
query IssueQuery($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) { id ...IssueDetail_issue }
  }
}
```

The record is keyed by that `id` from then on, whatever path reached it, so
every later read, by any operation, finds the same record.

## Refresh through `nodes(ids:)`

Once the ids are known, one operation refreshes any number of them: GitHub's
`nodes(ids: [ID!]!)` returns the records in the order asked, and the sample
spreads the same row fragments its lists render:

```graphql
query RefreshRowsQuery($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on Issue { id ...IssueRow_issue @alias }
    ... on PullRequest { id ...PullRequestRow_pullRequest @alias }
  }
}
```

```swift
let ids = rows.compactMap { $0.asIssue?.id ?? $0.asPullRequest?.id }
try await environment.fetch(RefreshRowsQuery(ids: Array(ids.prefix(50))))
```

In Kotlin the same two lines, `fetch` a `suspend` function:

```kotlin
val ids = rows.mapNotNull { it.asIssue?.id ?: it.asPullRequest?.id }
environment.fetch(RefreshRowsQuery(ids = ids.take(50)))
```

The response commits into the records the lists already show, by identity,
so every row re-renders with its new fields and nothing else changes; the
list's own query is not refetched, and its connection's edges stay where
they were. Fifty ids a request is GitHub's comfortable batch; Caton, the
app this pattern comes from, refreshed five hundred subjects in ten requests
where discovery had cost five hundred.

## Why not a variable-length batch of aliases

A compiler feature that expands `issue(number:)` into as many aliases as
the app has keys would be a concept for one app's cold start, and the
discovery cost is paid once per subject, not per launch: after it, the id
is in the store and the image. `nodes(ids:)` is the server's batch, and
Baton's identity makes the two halves meet in one record.
