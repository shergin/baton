# fate's GraphQL template

Responses recorded on 2026-10-09 from the server of fate's `graphql`
template (`packages/create-fate/templates/fate/graphql/` in
nkzw-tech/fate at `15af87c`, `@nkzw/fate` 1.7.7): Pothos and GraphQL Yoga
over Prisma and Postgres 17, seeded with the template's own data, run as
the template ships with no change. They are the server's bytes; the
documents that asked for them are in
`swift/Tests/BatonFateTests/FateDocuments.swift`, sent as `batonc print`
writes them.

- `schema.graphql`: the SDL the server writes at start in development.
- `posts-page-1.json`, `posts-page-2.json`: `FatePostsQuery` and
  `FatePostsPaginationQuery` after the first page's end cursor, over the
  `posts` connection on the query root.
- `post.json`: `FatePostQuery`, one post by `node(id:)`.
- `post-add.json`: `FatePostAdd`, signed in as the seeded user Alex.
- `post-live.sse`: the `text/event-stream` body of `FatePostLive` on
  `/graphql/stream` (graphql-sse, distinct connections), with the two
  `postLike` mutations that followed it; the stream was cut by the client.

The live events show the limit of the template's subscriptions for a
normalized client: `fateLiveNode` answers a `JSON` scalar keyed by the
database id, not typed fields under the post's global id, so its events
land at the subscription root and leave the post's record as it was.
