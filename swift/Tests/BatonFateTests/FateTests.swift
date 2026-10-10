import Baton
import BatonSpec
import BatonTesting
import Foundation
import Testing

/// A response recorded from the server of fate's GraphQL template, by file
/// name under `spec/fate/`.
func recorded(_ name: String) -> Data {
    Spec.data("fate/\(name)")
}

/// The payloads of the `next` events in the `text/event-stream` body the
/// server sent for the live view of one post, split as the transport splits
/// them.
func liveEvents() -> [Data] {
    var parser = EventStreamParser()
    return parser.push(recorded("post-live.sse")) + parser.finish()
}

/// The post every recording reads, by the global id the server gives it.
let postID = "Post-01a12372-b62b-7122-aff3-029976170578"

/// A transport that answers each query with its recorded response: the
/// first page of posts, the page after its end cursor and the one post.
func fateTransport() -> RecordedTransport {
    RecordedTransport([
        FatePostsQuery.name: recorded("posts-page-1.json"),
        FatePostsPaginationQuery.name: recorded("posts-page-2.json"),
        FatePostQuery.name: recorded("post.json"),
        FatePostAdd.name: recorded("post-add.json"),
    ])
}

@MainActor
@Suite("A client of fate's GraphQL template", .timeLimit(.minutes(1)))
struct FateTests {
    /// The posts screen, fetched and held as a view on screen holds it.
    func postsScreen(_ environment: Environment) async throws -> (FatePosts_query.Posts, Retention) {
        let handle = environment.handle(for: FatePostsQuery())
        let retention = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the first page did not arrive") }
        return (try #require(data.fatePosts.posts), retention)
    }

    @Test("the posts connection on the query root normalizes, reads through the lenses and pages after its end cursor")
    func the_posts_connection_normalizes_reads_and_pages() async throws {
        let transport = fateTransport()
        let environment = Environment(transport: transport)
        environment.log = nil
        let (posts, retention) = try await postsScreen(environment)

        #expect(posts.nodes.map(\.title) == ["What the Void example proves", "An incremental adoption checklist", "Moving away from request-centric state"])
        #expect(posts.nodes.map(\.author.name) == ["Sora", "Noah", "Mika"])
        #expect(posts.nodes.first?.likes == 86)
        #expect(posts.hasNext)

        try await posts.loadNext()
        #expect(transport.requests.last?.variables["cursor"] == .string("R1BDOlM6MDFhMTIzNzItYjYyYS03MGM2LThlZjQtMGQ3YzRlNGY1OWMz"))
        #expect(posts.nodes.map(\.title) == [
            "What the Void example proves", "An incremental adoption checklist", "Moving away from request-centric state",
            "Garbage collection for request lifetimes", "Stable refs and smaller rerenders", "The Vite plugin replaces everyday codegen",
        ])
        withExtendedLifetime(retention) {}
    }

    @Test("a post fetched by node(id:) is the record the connection's edge links, so the two reads agree")
    func a_post_by_node_is_the_record_the_connection_links() async throws {
        let environment = Environment(transport: fateTransport())
        environment.log = nil
        let (posts, retention) = try await postsScreen(environment)

        let handle = environment.handle(for: FatePostQuery(id: postID))
        let held = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the post did not arrive") }
        let post = try #require(data.node?.asPost)
        #expect(post.id == postID)
        #expect(post.commentCount == 2)
        #expect(post.content.hasPrefix("The Void example uses the same fate ideas"))
        #expect(posts.nodes.first?.id == post.id)
        #expect(posts.nodes.first?.title == post.title)
        withExtendedLifetime((retention, held)) {}
    }

    @Test("postAdd with @prependNode puts the server's post first in the posts connection")
    func post_add_prepends_its_node_to_the_connection() async throws {
        let environment = Environment(transport: fateTransport())
        environment.log = nil
        let (posts, retention) = try await postsScreen(environment)

        let mutation = FatePostAdd(input: PostAddInput(content: "A native client of the GraphQL template.", title: "Baton reads fate"), connections: [posts.connectionID])
        let result = try await environment.mutate(mutation)
        #expect(result.postAdd?.id == "Post-01a12375-c75d-716d-9d1f-fb0b2f0c3456")
        #expect(posts.nodes.map(\.title) == ["Baton reads fate", "What the Void example proves", "An incremental adoption checklist", "Moving away from request-centric state"])
        #expect(posts.nodes.first?.author.name == "Alex")
        #expect(posts.nodes.first?.likes == 0)
        withExtendedLifetime(retention) {}
    }

    @Test("fateLiveNode's events arrive over graphql-sse and normalize at the subscription root, and their JSON payload leaves the post's record as it was")
    func live_node_events_land_at_the_subscription_root_only() async throws {
        let transport = ScriptedTransport([FatePostQuery.name: recorded("post.json")])
        let environment = Environment(transport: transport, subscriptions: transport)
        environment.log = nil

        let handle = environment.handle(for: FatePostQuery(id: postID))
        let held = handle.retain()
        await handle.settle()
        guard case .ready(let data) = handle.phase else { throw TransportError(statusCode: 0, body: "the post did not arrive") }
        let post = try #require(data.node?.asPost)
        #expect(post.likes == 86)

        let live = environment.subscriptionHandle(for: FatePostLive(id: postID, select: ["title", "likes"]))
        let retention = live.retain()
        #expect(await wait(until: { transport.driven.count == 1 }))
        let driven = try #require(transport.driven.first)
        let events = liveEvents()
        #expect(events.count == 2)
        for event in events { driven.send(event) }
        #expect(await wait(until: { live.events == 2 }))

        // The event is the server's, read through the lens at the
        // subscription root: its `id` is the database id, not the global id
        // the post's record is keyed by, and `data` is a `JSON` scalar, read
        // as the text the server wrote.
        let event = try #require(live.latest?.fateLiveNode)
        #expect(event.id == "01a12372-b62b-7122-aff3-029976170578")
        #expect(event.select == ["likes"])
        #expect(event.delete == nil)
        #expect(event.data == #"{"id":"01a12372-b62b-7122-aff3-029976170578","likes":88}"#)

        // Nothing in the event names the post's record, so the record keeps
        // the likes the query read.
        #expect(post.likes == 86)
        withExtendedLifetime((held, retention)) {}
    }
}
