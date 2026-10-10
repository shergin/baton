package baton.fate

import baton.Environment
import baton.EventStreamParser
import baton.Hold
import baton.Phase
import baton.Spec
import baton.Store
import baton.Transport
import baton.Variable
import baton.testing.RecordedTransport
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * A client of fate's GraphQL template: the documents in `FateDocuments.kt`
 * read through the responses recorded from its server under `spec/fate/`,
 * as `swift/Tests/BatonFateTests/FateTests.swift` reads them.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FateTests {
    /** A response recorded from the server of fate's GraphQL template, by file name under `spec/fate/`. */
    private fun recorded(name: String): ByteArray = Spec.bytes("fate/$name")

    /**
     * The payloads of the `next` events in the `text/event-stream` body the
     * server sent for the live view of one post, split as the transport
     * splits them.
     */
    private fun liveEvents(): List<ByteArray> {
        val parser = EventStreamParser()
        return parser.push(recorded("post-live.sse")) + parser.finish()
    }

    /**
     * A transport that answers each operation with its recorded response:
     * the first page of posts, the page after its end cursor, the one post
     * and the added post.
     */
    private fun fateTransport(): RecordedTransport = RecordedTransport(
        mapOf(
            FatePostsQuery.name to recorded("posts-page-1.json"),
            FatePostsPaginationQuery.name to recorded("posts-page-2.json"),
            FatePostQuery.name to recorded("post.json"),
            FatePostAdd.name to recorded("post-add.json"),
        ),
    )

    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher, with no log. */
    private fun TestScope.environment(transport: Transport, subscriptions: Transport? = null): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, subscriptions, Store(), dispatcher, dispatcher).also { it.log = null }
    }

    /** The posts screen, fetched and held as a composable on screen holds it. */
    private suspend fun TestScope.postsScreen(environment: Environment): Pair<FatePosts_query.Posts, Hold> {
        val handle = environment.handle(FatePostsQuery())
        val hold = handle.retain()
        runCurrent()
        handle.settle()
        val data = assertIs<Phase.Ready<FatePostsQuery.Data>>(handle.phase, "the first page arrives").data
        return assertNotNull(data.fatePosts.posts) to hold
    }

    @Test
    fun `the posts connection on the query root normalizes, reads through the lenses and pages after its end cursor`() = runTest {
        val transport = fateTransport()
        val environment = environment(transport)
        val (posts, hold) = postsScreen(environment)

        assertEquals(listOf("What the Void example proves", "An incremental adoption checklist", "Moving away from request-centric state"), posts.nodes.map { it.title })
        assertEquals(listOf("Sora", "Noah", "Mika"), posts.nodes.map { it.author.name })
        assertEquals(86, posts.nodes.firstOrNull()?.likes)
        assertTrue(posts.hasNext)

        posts.loadNext()
        assertEquals(Variable.String("R1BDOlM6MDFhMTIzNzItYjYyYS03MGM2LThlZjQtMGQ3YzRlNGY1OWMz"), transport.requests.last().variables["cursor"])
        assertEquals(
            listOf(
                "What the Void example proves", "An incremental adoption checklist", "Moving away from request-centric state",
                "Garbage collection for request lifetimes", "Stable refs and smaller rerenders", "The Vite plugin replaces everyday codegen",
            ),
            posts.nodes.map { it.title },
        )
        hold.release()
        environment.end()
    }

    @Test
    fun `a post fetched by node(id) is the record the connection's edge links, so the two reads agree`() = runTest {
        val environment = environment(fateTransport())
        val (posts, hold) = postsScreen(environment)

        val handle = environment.handle(FatePostQuery(id = POST_ID))
        val held = handle.retain()
        runCurrent()
        handle.settle()
        val data = assertIs<Phase.Ready<FatePostQuery.Data>>(handle.phase, "the post arrives").data
        val post = assertNotNull(data.node?.asPost)
        assertEquals(POST_ID, post.id)
        assertEquals(2, post.commentCount)
        assertTrue(post.content.startsWith("The Void example uses the same fate ideas"), post.content)
        assertEquals(post.id, posts.nodes.firstOrNull()?.id)
        assertEquals(post.title, posts.nodes.firstOrNull()?.title)
        held.release()
        hold.release()
        environment.end()
    }

    @Test
    fun `postAdd with prependNode puts the server's post first in the posts connection`() = runTest {
        val environment = environment(fateTransport())
        val (posts, hold) = postsScreen(environment)

        val mutation = FatePostAdd(
            input = PostAddInput(content = "A native client of the GraphQL template.", title = "Baton reads fate"),
            connections = listOf(posts.connectionID),
        )
        val result = environment.mutate(mutation)
        assertEquals("Post-01a12375-c75d-716d-9d1f-fb0b2f0c3456", result.postAdd?.id)
        assertEquals(
            listOf("Baton reads fate", "What the Void example proves", "An incremental adoption checklist", "Moving away from request-centric state"),
            posts.nodes.map { it.title },
        )
        assertEquals("Alex", posts.nodes.firstOrNull()?.author?.name)
        assertEquals(0, posts.nodes.firstOrNull()?.likes)
        hold.release()
        environment.end()
    }

    @Test
    fun `fateLiveNode's events arrive over graphql-sse and normalize at the subscription root, and their JSON payload leaves the post's record as it was`() = runTest {
        val transport = ScriptedTransport(answers = mapOf(FatePostQuery.name to recorded("post.json")))
        val environment = environment(transport, subscriptions = transport)

        val handle = environment.handle(FatePostQuery(id = POST_ID))
        val held = handle.retain()
        runCurrent()
        handle.settle()
        val data = assertIs<Phase.Ready<FatePostQuery.Data>>(handle.phase, "the post arrives").data
        val post = assertNotNull(data.node?.asPost)
        assertEquals(86, post.likes)

        val live = environment.subscriptionHandle(FatePostLive(id = POST_ID, select = listOf("title", "likes")))
        val hold = live.retain()
        runCurrent()
        val driven = transport.driven.single()
        val events = liveEvents()
        assertEquals(2, events.size)
        for (event in events) driven.send(event)
        runCurrent()
        assertEquals(2, live.events)

        // The event is the server's, read through the lens at the
        // subscription root: its `id` is the database id, not the global id
        // the post's record is keyed by, and `data` is a `JSON` scalar, read
        // as the text the server wrote.
        val event = assertNotNull(live.latest?.fateLiveNode)
        assertEquals("01a12372-b62b-7122-aff3-029976170578", event.id)
        assertEquals(listOf("likes"), event.select)
        assertNull(event.delete)
        assertEquals("""{"id":"01a12372-b62b-7122-aff3-029976170578","likes":88}""", event.data)

        // Nothing in the event names the post's record, so the record keeps
        // the likes the query read.
        assertEquals(86, post.likes)
        hold.release()
        held.release()
        environment.end()
        for (stream in transport.driven) stream.complete()
        runCurrent()
    }

    private companion object {
        /** The post every recording reads, by the global id the server gives it. */
        const val POST_ID = "Post-01a12372-b62b-7122-aff3-029976170578"
    }
}
