# Why GraphQL

You build iOS or Android screens on REST and view models. This is what
GraphQL changes, what it still leaves you, and what it costs. The words are
defined in [`terminology.md`](terminology.md).

## The problem

Take an issue screen. You want the title, the author's name and avatar, and
the comments, each with its author. On REST that takes:

1. `GET /issues/42`, then, from its answer, `GET /users/7` and
   `GET /issues/42/comments`, then the users of the comments. The round
   trips run in sequence. Each waits on the last. Each response carries
   fields the screen never shows.
2. Model structs for each response, decoders, and a view model. The view
   model calls the endpoints, merges the answers, and copies the fields
   each view needs into its own properties.
3. A cache keyed by URL. The issue the list screen fetched and the issue
   the detail screen fetched are two copies. Star it on one and the other
   is wrong until someone writes the code that updates it.
4. A contract the compiler never sees. A field the server renamed is a
   decoding failure in production.

None of this is the screen. It is plumbing. It is most of the code.

## What GraphQL solves

The server publishes a **schema**: every type, every field, and which of
them are nullable. You send one document naming the fields you want, nested
as deep as the screen goes. You get exactly that shape back:

```graphql
query IssueQuery($id: ID!) {
  issue(id: $id) {
    title
    author { name avatarUrl }
    comments(first: 20) {
      edges { node { body author { name avatarUrl } } }
    }
  }
}
```

One round trip, and nothing extra in it (problem 1). The document is checked
against the schema at build time. A misspelled or removed field is a build
error (problem 4). Objects carry an `id`, so a client can store each object
once, by type and id, rather than once per request.

GraphQL is the API layer, where REST is today. It is not a database
language. The server resolves each field however it likes. The request is
still HTTP and JSON.

## What GraphQL alone does not solve

A query per screen moves the plumbing. It does not remove it. The screen's
query lists the fields of every view on it. A row that starts showing a
date means editing a query in another file. The response is decoded into a
model tree. A view model still copies from it. The cache still needs
someone to keep the list and the detail in agreement (problems 2 and 3).
That is how most native GraphQL clients work. It is why GraphQL on mobile
often feels like more work than REST.

## What Relay solves

Relay puts the data a view reads beside the view.

- **A fragment per view.** A fragment is the fields one view reads, written
  next to its body. The compiler assembles the screen's one query from the
  fragments of its views. A row that shows a date adds `createdAt` to its
  own fragment. Nothing else changes.
- **A view reads only what it declared.** The parent hands the child a
  reference, not data. The child reads its own fields through it.
- **One store.** Every response is normalized into records by type and id.
  The list and the detail read the same record, so a change shows in both.
- **Declarative writes.** A mutation selects what it changed. It names the
  list it adds to with a directive. It may carry an optimistic response,
  which shows at once and reverts if the server refuses it. No code edits
  the cache.

The view model's data work, the decoding and the cache updates are gone
(problems 2 and 3).

## What Baton adds

Relay is for React. Baton brings it to SwiftUI and Compose, with the same
compiler front end and the same directives.

```swift
struct CommentRow: View {
    @Fragment("""
    fragment CommentRow_comment on IssueComment {
      body
      author { login }
    }
    """)
    var comment: CommentRow_comment

    var body: some View {
        Text(comment.author?.login ?? "ghost").font(.caption)
        Text(comment.body)
    }
}
```

The fragment compiles to a typed [lens](terminology.md#generated) over the
store's records. A lens is a typed window onto one record. SwiftUI's
Observation and Compose's snapshot state observe the records directly. A
view re-renders when a field it read changes, and at no other time. A
screen whose data is already in the store renders it in the first frame.
No GraphQL is parsed on the device. The [README](../README.md) has the
Compose spelling and the numbers.

## What stays yours

Navigation, view controllers, presentation and lifecycle are the
platform's, as before. A UIKit or AppKit controller holds the same handle a
view does ([UIKit and AppKit](recipes/uikit.md)). State that belongs to the
user's interaction stays in the view, or in the app's own model: a draft, a
selection, an open sheet. Authentication and retries wrap the one
[transport](terminology.md#runtime) function
([the exchange](recipes/exchange.md)).

## What it costs

- **A GraphQL server.** If the backend is REST, a GraphQL layer stands in
  front of it, and someone owns it. Any server that follows the
  specification works ([your server](../README.md#works-with-your-server)).
- **A schema in the build.** The compiler reads the schema's SDL. A change
  to it is a change the build sees.
- **Server discipline.** Clients choose the shape, so the server guards
  against expensive selections. Persisted operations narrow that to the
  documents the apps were built with
  ([persisted id](terminology.md#compiler)).
- **New habits.** A fragment per view, and no copied state.
  [`recipes/agents.md`](recipes/agents.md) states the shape of a screen in
  one page.
