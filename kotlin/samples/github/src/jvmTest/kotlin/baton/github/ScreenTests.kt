package baton.github

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertAny
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onChildren
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import baton.Environment
import baton.LocalBaton
import baton.OperationKind
import baton.Store
import baton.Variable
import baton.testing.ScriptedTransport
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test

/**
 * The screens over a scripted transport, answered with the small responses
 * under `responses/`, in a composition on the desktop's event thread, as the
 * app runs them.
 */
class ScreenTests {
    @get:Rule
    val rule = createComposeRule()

    /** Provides an environment over [transport], made in the composition on its thread, as the app makes one after sign-in. */
    @Composable
    private fun Provided(transport: ScriptedTransport, content: @Composable () -> Unit) {
        val environment = remember { Environment(transport, store = Store()) }
        CompositionLocalProvider(LocalBaton provides environment, content = content)
    }

    private fun response(name: String): ByteArray =
        checkNotNull(ScreenTests::class.java.getResource("/responses/$name.json")) { "no response named $name" }.readBytes()

    private fun waitForText(text: String) {
        rule.waitUntil(5_000) { rule.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
    }

    private val unstarred = "☆ Star · 2600"
    private val starred = "★ Starred · 2601"

    @Test
    fun the_repository_screen_shows_the_recorded_repository() {
        // The default window shows the first page's end, so the list asks for the next one.
        val transport = ScriptedTransport(
            mapOf(
                "RepositoryQuery" to response("repository"),
                "IssueListPaginationQuery" to response("issues-after-c3"),
            ),
        )
        rule.setContent {
            Provided(transport) { RepositoryScreen("octocat", "Hello-World", onSelect = {}) }
        }
        waitForText("octocat/Hello-World")
        rule.onNodeWithText("My first repository on GitHub!").assertExists()
        rule.onNodeWithText("4 forks").assertExists()
        rule.onNodeWithText(unstarred).assertExists()
        rule.onNodeWithText("6 open issues").assertExists()
        rule.onNodeWithText("Sixth issue").assertExists()
        rule.onNodeWithText("#5 · hubot · open").assertExists()
        val variables = transport.requests.first().variables
        assertEquals(Variable.String("octocat"), variables["owner"])
        assertEquals(Variable.String("Hello-World"), variables["name"])
    }

    @Test
    fun pressing_the_star_flips_the_star_and_the_count_before_the_server_answers_and_keeps_them_when_it_answers_in_kind() {
        // The default window shows the first page's end, so the list asks for the next one.
        val transport = ScriptedTransport(
            mapOf(
                "RepositoryQuery" to response("repository"),
                "IssueListPaginationQuery" to response("issues-after-c3"),
            ),
        )
        rule.setContent {
            Provided(transport) { RepositoryScreen("octocat", "Hello-World", onSelect = {}) }
        }
        waitForText(unstarred)
        rule.onNodeWithTag("star").performClick()
        rule.waitUntil(5_000) { transport.held.size == 1 }
        val held = transport.held.single()
        assertEquals("StarButtonAddStar", held.request.operationName)
        waitForText(starred)
        rule.onNodeWithText(unstarred).assertDoesNotExist()

        rule.runOnIdle { held.respond(response("add-star")) }
        rule.waitUntil(5_000) { transport.held.isEmpty() }
        rule.waitUntil(5_000) { rule.onAllNodes(hasTestTag("star") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText(starred).assertExists()
        rule.onNodeWithText(unstarred).assertDoesNotExist()
        assertEquals(1, transport.requests(OperationKind.MUTATION).size)
    }

    @Test
    fun a_second_page_appends_when_the_list_reaches_its_end() {
        val transport = ScriptedTransport(
            mapOf(
                "RepositoryQuery" to response("repository"),
                "IssueListPaginationQuery" to response("issues-after-c3"),
            ),
        )
        rule.setContent {
            Provided(transport) {
                // A short window, so the first page overflows it and its end is out of sight.
                Box(Modifier.width(440.dp).height(320.dp)) {
                    RepositoryScreen("octocat", "Hello-World", onSelect = {}, modifier = Modifier.fillMaxSize())
                }
            }
        }
        waitForText("octocat/Hello-World")
        rule.waitForIdle()
        assertEquals(listOf("RepositoryQuery"), transport.requests.map { it.operationName }, "no page is asked for before the end is reached")

        // The header, the four issues, and the spinner that asks for the next page.
        rule.onNodeWithTag("issues").performScrollToIndex(5)
        rule.waitUntil(5_000) { transport.requests.size == 2 }
        val page = transport.requests.last()
        assertEquals("IssueListPaginationQuery", page.operationName)
        assertEquals(Variable.String("c3"), page.variables["cursor"])
        assertEquals(Variable.String("R_1"), page.variables["id"])

        rule.waitUntil(5_000) {
            runCatching { rule.onNodeWithTag("issues").performScrollToNode(hasText("First issue")) }.isSuccess
        }
        rule.onNodeWithText("Second issue").assertExists()
        rule.waitForIdle()
        assertEquals(2, transport.requests.size, "the last page asks for no other")
    }

    @Test
    fun a_posted_comment_appears_at_the_end_of_the_comments_at_once_and_stays_when_the_server_answers() {
        val transport = ScriptedTransport(
            mapOf(
                "IssueQuery" to response("issue"),
                "ViewerQuery" to response("viewer"),
            ),
        )
        rule.setContent {
            Provided(transport) { IssueScreen("I_6") }
        }
        waitForText("Sixth issue")
        rule.onAllNodesWithTag("comment").assertCountEquals(2)
        rule.onNodeWithTag("composer").performTextInput("Looking into it.")
        // The button waits for the viewer, whose comment the optimistic one is.
        rule.waitUntil(5_000) { rule.onAllNodes(hasText("Comment") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithText("Comment").assertIsEnabled().performClick()

        rule.waitUntil(5_000) { transport.held.size == 1 }
        val held = transport.held.single()
        assertEquals("CommentComposerAddComment", held.request.operationName)
        val connections = held.request.variables["connections"]
        assertTrue(connections is Variable.List && connections.values.size == 1, "the comments connection is named: $connections")
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("comment").fetchSemanticsNodes().size == 3 }
        rule.onAllNodesWithTag("comment").onLast().onChildren().assertAny(hasText("Looking into it."))
        rule.onAllNodesWithTag("comment").onLast().onChildren().assertAny(hasText("triager", substring = true))

        rule.runOnIdle { held.respond(response("add-comment")) }
        rule.waitUntil(5_000) { transport.held.isEmpty() }
        rule.waitForIdle()
        rule.onAllNodesWithTag("comment").assertCountEquals(3)
        rule.onAllNodesWithTag("comment").onLast().onChildren().assertAny(hasText("Looking into it."))
        rule.onAllNodesWithTag("comment").onLast().onChildren().assertAny(hasText("triager · 2026-10-07"))
    }
}
