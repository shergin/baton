package baton

import baton.spec.TestRepeatedPlainNotes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * What the ingest does with an entity's object the response prints again
 * under one selection: a printing equal byte for byte to an earlier one is
 * taken as that printing's record, and its entries are appended again only
 * where a later printing wrote one of its records since. Mirrors
 * `swift/Tests/BatonTests/RepeatTests.swift`.
 */
class RepeatTests {
    private val operation = TestRepeatedPlainNotes()

    /**
     * A page of notes for each of two characters, each holding note `n5`,
     * whose text in Morty's page is [mortysText]; Rick's printing comes
     * again after Morty's, byte for byte. The text runs past the 64 bytes
     * the ingest hashes, so a note's printing is found by its bytes alone.
     */
    private fun nestedNotes(mortysText: String): ByteArray {
        fun page(id: String, text: String) =
            """{"id":"$id","notes":{"edges":[{"cursor":"c1","node":{"__typename":"Note","id":"n5","text":"$text"}}],"pageInfo":{"endCursor":"c1","hasNextPage":false}}}"""
        val rick = page("1", RICKS_TEXT)
        return """{"data":{"characters":{"results":[$rick,${page("2", mortysText)},$rick]}}}""".encodeToByteArray()
    }

    private fun normalize(store: Store, response: ByteArray): ChangeSet =
        Ingest.normalize(response, store.resolve(TestRepeatedPlainNotes.plan, operation.variables), Store.ROOT_KEY)

    /** The text of `Note:n5` in [store]. */
    private fun noteText(store: Store): Value {
        val note = assertNotNull(store.existing("Note:n5"))
        return note.peek(Registry.slot(note.type, "text"))
    }

    @Test
    fun `an entity printed again whose records no later printing wrote appends nothing and reads as before`() {
        val store = Store()
        val rick = """{"id":"1","notes":{"edges":[],"pageInfo":{"endCursor":null,"hasNextPage":false}}}"""
        val morty = """{"id":"2","notes":{"edges":[{"cursor":"c1","node":{"__typename":"Note","id":"n5","text":"Aw geez"}}],"pageInfo":{"endCursor":"c1","hasNextPage":false}}}"""
        val changes = normalize(store, """{"data":{"characters":{"results":[$rick,$morty,$rick]}}}""".encodeToByteArray())
        assertEquals(1, changes.skipped)
        assertEquals(changes.entryCount, changes.entriesBeforeGrouping)
        store.commit(changes)
        assertEquals(Value.String("Aw geez"), noteText(store))
        val list = assertNotNull(store.existing("client:root:characters(page:1)"))
        val results = list.peek(Registry.slot(list.type, "results")) as Value.Refs
        assertEquals(listOf("Character:1", "Character:2", "Character:1"), results.records.map { it?.key })
    }

    @Test
    fun `an entity printed again after a child entity of its subtree was printed elsewhere with other values reads the child's values from the last printing`() {
        val store = Store()
        val changes = normalize(store, nestedNotes("Aw geez Rick, that is not what the note said in the garage at all"))
        // The root's two entries, Rick's ten and Morty's eight beside the
        // note stand after grouping; before it, Morty's two for the note and
        // Rick's ten appended again in the third printing's place.
        assertEquals(1, changes.skipped)
        assertEquals(20, changes.entryCount)
        assertEquals(32, changes.entriesBeforeGrouping)
        store.commit(changes)
        assertEquals(Value.String(RICKS_TEXT), noteText(store))
    }

    @Test
    fun `an entity printed again after a child entity of its subtree was printed elsewhere byte for byte appends nothing`() {
        val store = Store()
        val changes = normalize(store, nestedNotes(RICKS_TEXT))
        assertEquals(2, changes.skipped)
        assertEquals(changes.entryCount, changes.entriesBeforeGrouping)
        store.commit(changes)
        assertEquals(Value.String(RICKS_TEXT), noteText(store))
    }

    private companion object {
        const val RICKS_TEXT = "Wubba lubba dub dub, said in a garage in Dimension C-137"
    }
}
