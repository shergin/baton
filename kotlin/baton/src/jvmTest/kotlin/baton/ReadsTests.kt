package baton

import baton.spec.TestList
import baton.spec.TestNotesQuery
import baton.spec.TestProfileQuery
import baton.spec.TestStrictQuery
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The response is the oracle for the reads too: each case's `reads` rows,
 * read through the lenses the compiler generated from `spec/sources`, yield
 * the values the rows hold, and a row whose `note` names a rule has that
 * rule asserted.
 */
class ReadsTests {
    /** A case committed into an empty store, the log recorded from then on, and the operation's lens over its root. */
    private class Reading(val case: Spec.Case) {
        val store = Store()
        val events = ArrayList<LogEvent>()
        val data: Lens

        init {
            case.commit(store)
            store.log = { events.add(it) }
            val type = checkNotNull(case.type) { "no generated operation ${case.operation}" }
            data = type.data(Anchor(store.root(case.kind), Owner(case.variables, store)))
        }

        /** The value at a row's path over the operation's lens. */
        fun walk(path: String): Any? = walk(data, path)
    }

    /** The rules a row's `note` names, by case and path, each asserted after the row is read. */
    private val rules: Map<String, (Reading) -> Unit> = run {
        fun character(reading: Reading) = assertNotNull((reading.data as TestProfileQuery.Data).character)
        val strictThrows: (Reading) -> Unit = { reading ->
            val error = assertFailsWith<FieldErrors>("a @throwOnFieldError fragment with an error inside throws at the spread") { character(reading).strict }
            assertTrue(error.errors.any { it.path == "type" }, "${error.errors}")
        }
        val absentProfile: (Reading) -> Unit = { reading ->
            assertNull(character(reading).testProfile, "a @required field that is null leaves the fragment absent")
        }
        fun unexpected(field: String): (Reading) -> Unit = { reading ->
            assertTrue(LogEvent.Unexpected("Asset", field) in reading.events, "the text that does not convert is reported as unexpected: ${reading.events}")
            assertTrue(reading.events.none { it is LogEvent.Missing }, "and never as missing")
        }
        val clientAbsent: (Reading) -> Unit = { reading ->
            assertTrue(reading.events.none { it is LogEvent.Missing }, "a client field no payload wrote reports nothing missing: ${reading.events}")
        }
        val clientWritten: (Reading) -> Unit = { reading ->
            assertTrue(reading.events.isEmpty(), "a client field a payload wrote reads as any field does: ${reading.events}")
        }
        val lastPrinting: (Reading) -> Unit = { reading ->
            val results = assertNotNull(assertNotNull((reading.data as TestList.Data).characters).results)
            assertEquals(1, results.map { it.recordID }.toSet().size, "the character's printings are one record, which holds the value of the last")
        }
        mapOf(
            "tests/character-errors character.species" to strictThrows,
            "tests/character-errors-answered character.species" to strictThrows,
            "tests/character-origin-null character.name" to absentProfile,
            "tests/character-origin-null character.status" to absentProfile,
            "tests/character-origin-null character.location.name" to absentProfile,
            "tests/asset-prices assets.1.price" to unexpected("price"),
            "tests/asset-prices assets.1.page" to unexpected("page"),
            "tests/asset-prices assets.1.prices" to unexpected("prices"),
            "tests/asset-prices assets.2.listedAt" to unexpected("listedAt"),
            "tests/pinned-character character.isPinned" to clientAbsent,
            "tests/pinned-character character.note" to clientAbsent,
            "tests/pin-character character.isPinned" to clientWritten,
            "tests/pin-character character.note" to clientWritten,
            "tests/drafts drafts.0.id" to clientWritten,
            "tests/character-printed-two-ways characters.results.0.species" to lastPrinting,
            "tests/character-printed-two-ways-and-back characters.results.1.species" to lastPrinting,
        )
    }

    @Test
    fun `every reads row of every case reads through the generated lenses as the case says`() {
        val failures = ArrayList<String>()
        var rows = 0
        for (case in Spec.cases) {
            val reading = try {
                Reading(case)
            } catch (error: Exception) {
                failures.add("${case.name}: $error")
                continue
            }
            for (row in case.reads) {
                rows += 1
                reading.events.clear()
                val actual = try {
                    reading.walk(row.path)
                } catch (error: Throwable) {
                    failures.add("${case.name} ${row.path}: $error")
                    continue
                }
                if (!matches(actual, row.value)) failures.add("${case.name} ${row.path}: read $actual, the case says ${row.value}")
                if (row.note == null) continue
                val rule = rules["${case.name} ${row.path}"]
                if (rule == null) {
                    failures.add("${case.name} ${row.path}: no assertion for the rule \"${row.note}\"")
                    continue
                }
                try {
                    rule(reading)
                } catch (error: AssertionError) {
                    failures.add("${case.name} ${row.path}: ${error.message}")
                }
            }
        }
        assertTrue(rows > 0)
        if (failures.isNotEmpty()) fail("${failures.size} of $rows rows differ:\n" + failures.joinToString("\n"))
    }

    @Test
    fun `a connection reads its nodes, its page info and its state from the connection record`() {
        val reading = Reading(Spec.case("tests/notes-page-1"))
        val notes = assertNotNull((reading.data as TestNotesQuery.Data).character).testNotes.notes
        assertEquals(listOf("n1", "n2"), notes.nodes.map { it.id })
        assertEquals(notes.edges?.map { it.node }, notes.nodes, "the nodes are the edges' nodes, equal by anchor")
        assertEquals(listOf("c1", "c2"), notes.edges?.map { it.cursor })
        assertEquals("c2", notes.pageInfo.endCursor)
        assertTrue(notes.pageInfo.hasNextPage)
        assertTrue(notes.hasNext)
        assertFalse(notes.hasPrevious)
        assertFalse(notes.isLoadingNext)
        assertFalse(notes.isLoadingPrevious)
        assertEquals("Character:1:__TestNotes_notes_connection", notes.connectionID)
        assertTrue(reading.events.isEmpty(), "a complete case reports nothing: ${reading.events}")
    }

    @Test
    fun `a deferred spread is absent until its fields arrive`() {
        val first = Reading(Spec.case("tests/character-deferred-1"))
        assertNull(assertNotNull((first.data as TestProfileQuery.Data).character).testAppearances)
        val both = Reading(Spec.case("tests/character-deferred"))
        val appearances = assertNotNull(assertNotNull((both.data as TestProfileQuery.Data).character).testAppearances)
        assertEquals("Pilot", appearances.episode.first().name)
    }

    @Test
    fun `a field error is caught as a failure that carries it, and a caught link carries the errors inside it`() {
        val reading = Reading(Spec.case("tests/character-errors"))
        val profile = assertNotNull(assertNotNull((reading.data as TestProfileQuery.Data).character).testProfile)
        val image = profile.image.exceptionOrNull() as FieldErrors
        assertEquals(listOf("image service unavailable"), image.errors.map { it.message })
        val location = profile.location.exceptionOrNull() as FieldErrors
        assertEquals(listOf("location name redacted"), location.errors.map { it.message })
        assertEquals("Earth (C-137)", profile.origin.name)
    }

    @Test
    fun `an operation with throwOnFieldError fails with the error its selection carries`() {
        val reading = Reading(Spec.case("tests/character-name-hidden"))
        val failure = TestStrictQuery.Data.caught((reading.data as TestStrictQuery.Data).anchor).exceptionOrNull()
        assertEquals(listOf("name hidden"), (failure as FieldErrors).errors.map { it.message })
        val profile = Reading(Spec.case("tests/character-deferred-1")).data as TestProfileQuery.Data
        assertEquals("Genius", assertNotNull(profile.character).strict.type, "the throwing getter reads the value when there is one")
    }
}
