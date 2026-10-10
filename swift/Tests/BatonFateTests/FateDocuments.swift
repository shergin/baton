import Baton

/// The documents an app writes against the server of fate's GraphQL
/// template, compiled from the schema that server exports: a screen paging
/// the posts on the query root, one post by `node(id:)`, the mutation that
/// adds a post and puts it first in the screen's connection, and the live
/// view of one post through `fateLiveNode`.
@MainActor
struct FateDocuments {
    @Fragment("""
        fragment FatePosts_query on Query
        @refetchable(queryName: "FatePostsPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 3}, cursor: {type: "String"}) {
          posts(first: $count, after: $cursor) @connection(key: "FatePosts_posts") {
            edges { node { id title likes author { id name } } }
          }
        }
        """)
    var posts: FatePosts_query

    @Query("""
        query FatePostsQuery { ...FatePosts_query }
        """)
    var postsQuery: FatePostsQuery

    @Query("""
        query FatePostQuery($id: ID!) {
          node(id: $id) { ... on Post { id title content likes commentCount } }
        }
        """)
    var postQuery: FatePostQuery

    @Mutation("""
        mutation FatePostAdd($input: PostAddInput!, $connections: [ID!]!) {
          postAdd(input: $input)
          @prependNode(connections: $connections, edgeTypeName: "QueryPostsConnectionEdge") {
            id title likes author { id name }
          }
        }
        """)
    var postAdd: FatePostAdd.Action

    @Subscription("""
        subscription FatePostLive($id: ID!, $select: [String!]!) {
          fateLiveNode(id: $id, type: "Post", select: $select) { id delete select data }
        }
        """)
    var postLive: FatePostLive
}
