package fixture.screens

import baton.Environment
import baton.FetchPolicy
import baton.Phase
import baton.Store
import baton.testing.RecordedTransport
import fixture.shared.CharacterStatus_character
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest

/**
 * A module that spreads a fragment of its base reads it through the base's
 * lens: one store, one response, two modules that agree on the slots through
 * the process's registry. Nothing here opts in to the generated contract.
 */
class SpreadAcrossModulesTests {
    /**
     * The response a server gave for this operation's selection: the store
     * test of `spec/rickandmorty/character-header-9.json` selects the same
     * fields and one more, `image`, which this operation does not ask for.
     */
    private val characterNine: ByteArray =
        File(System.getProperty("baton.spec"), "rickandmorty/character-header-9.json").readBytes()

    @Test
    fun `the dependent's spread reads the response through the base's lens with the bound argument`() = runTest {
        val transport = RecordedTransport(mapOf(CharacterScreenQuery.name to characterNine))
        val dispatcher = StandardTestDispatcher(testScheduler)
        val environment = Environment(transport, null, Store(), dispatcher, dispatcher)

        environment.fetch(CharacterScreenQuery(id = "9"))
        val handle = environment.handle(CharacterScreenQuery(id = "9"), FetchPolicy.STORE_ONLY)
        val data = assertIs<Phase.Ready<CharacterScreenQuery.Data>>(handle.phase).data
        val row = assertNotNull(data.character).characterRow
        assertEquals("Agency Director", row.name)
        val status: CharacterStatus_character = row.characterStatus
        assertEquals("Dead", status.status)
        assertEquals("Human", status.species)
        assertEquals(
            "Earth (Replacement Dimension)",
            status.origin?.name,
            "the spread binds `full` to true, so the base's lens reads the field under `@include(if: \$full)`",
        )
        assertEquals("Agency Director: Dead, Human, Earth (Replacement Dimension)", characterRow(row))
        assertEquals(1, transport.requestCount)
        environment.end()
    }
}
