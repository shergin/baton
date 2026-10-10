package baton

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import baton.inspector.StoreInspector
import baton.spec.TestHeaderQuery
import baton.spec.TestRename
import baton.testing.ScriptedTransport
import org.junit.After
import org.junit.Rule
import org.junit.Test

/** The store inspector in a composition: what it lists, and that a commit moves it. */
class InspectorTests {
    @get:Rule
    val rule = createComposeRule()

    /** The environment the composition made, on the event thread. */
    private var environment: Environment? = null

    /**
     * Ends the environment on its thread however the test went. Left
     * running, its write observer would post a send of the apply
     * notifications to the event thread after every snapshot write the later
     * tests make.
     */
    @After
    fun endTheEnvironment() {
        val made = environment ?: return
        rule.onStoreThread { made.end() }
    }

    @Test
    fun the_inspector_lists_a_committed_record_and_a_later_commit_changes_its_shown_value() {
        val renamed = """{"data":{"rename":{"character":{"id":"5","name":"Jerry Prime"}}}}""".encodeToByteArray()
        val transport = ScriptedTransport(mapOf("TestRename" to renamed))
        transport.hold("TestHeaderQuery")
        rule.setContent {
            val made = remember { Environment(transport, transport, Store()).also { environment = it } }
            CompositionLocalProvider(LocalBaton provides made) {
                rememberQuery(TestHeaderQuery(id = "5"))
                StoreInspector(made)
            }
        }
        rule.waitForIdle()
        rule.onNodeWithText("Character:5").assertDoesNotExist()

        rule.runOnIdle { transport.held.single().respond(Spec.bytes("tests/character-header-5.json")) }
        rule.waitUntil(5_000) { shown("Character:5") == 1 }
        rule.onNodeWithText("Character:5").performClick()
        rule.onNodeWithText("\"Jerry Smith\"").assertExists()

        rule.onStoreThread { checkNotNull(environment).mutate(TestRename(id = "5", name = "Jerry Prime"), null) }
        rule.waitUntil(5_000) { shown("\"Jerry Prime\"") == 1 }
        rule.onNodeWithText("\"Jerry Smith\"").assertDoesNotExist()
    }

    /** How many nodes show [text] exactly. */
    private fun shown(text: String): Int = rule.onAllNodes(hasText(text)).fetchSemanticsNodes().size
}
