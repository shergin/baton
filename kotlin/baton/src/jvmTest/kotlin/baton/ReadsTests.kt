package baton

import java.math.BigDecimal
import java.net.URI
import java.time.Instant
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
 * read through the lenses written after the Swift goldens, yield the
 * values the rows hold, and a row whose `note` names a rule has that rule
 * asserted.
 */
class ReadsTests {
    /** A case committed into an empty store, the log recorded from then on, and the operation's lens over its root. */
    private class Reading(val case: Spec.Case) {
        val store = Store()
        val events = ArrayList<LogEvent>()
        val data: Walkable

        init {
            case.commit(store)
            store.log = { events.add(it) }
            val lens = checkNotNull(TestLenses.byOperation[case.operation]) { "no lens for ${case.operation}" }
            data = lens(Anchor(store.root(case.kind), Owner(case.variables, store)))
        }

        /**
         * The value at a row's path: a response key through the lens's
         * field table, an index into a list; a `Result` reads as its value
         * or as absent, and a getter that throws a field's error reads as
         * absent, as a fragment that throws does.
         */
        fun walk(path: String): Any? {
            var current: Any? = data
            for (segment in path.split('.')) {
                current = when (current) {
                    null -> return null
                    is List<*> -> current.getOrElse(segment.toInt()) { fail("$path: no element $segment") }
                    is Walkable -> try {
                        current.field(segment)
                    } catch (_: FieldErrors) {
                        null
                    } catch (_: RequiredFieldError) {
                        null
                    }
                    else -> fail("$path: $segment below a leaf")
                }
                if (current is Result<*>) current = current.getOrNull()
            }
            return current
        }
    }

    /** The rules a row's `note` names, by operation and path, each asserted after the row is read. */
    private val rules: Map<String, (Reading) -> Unit> = run {
        fun profile(reading: Reading) = assertNotNull((reading.data as TestProfileQuery.Data).character)
        val absentProfile: (Reading) -> Unit = { reading ->
            assertNull(profile(reading).testProfile, "a @required field that is null leaves the fragment absent")
        }
        fun unexpected(field: String): (Reading) -> Unit = { reading ->
            assertTrue(LogEvent.Unexpected("Asset", field) in reading.events, "the text that does not convert is reported as unexpected: ${reading.events}")
            assertTrue(reading.events.none { it is LogEvent.Missing }, "and never as missing")
        }
        mapOf(
            "TestProfileQuery character.species" to { reading ->
                val error = assertFailsWith<FieldErrors>("a @throwOnFieldError fragment with an error inside throws at the spread") { profile(reading).strict }
                assertTrue(error.errors.any { it.path == "type" }, "${error.errors}")
            },
            "TestProfileQuery character.name" to absentProfile,
            "TestProfileQuery character.status" to absentProfile,
            "TestProfileQuery character.location.name" to absentProfile,
            "TestAssetPricesQuery assets.1.price" to unexpected("price"),
            "TestAssetPricesQuery assets.1.page" to unexpected("page"),
            "TestAssetPricesQuery assets.1.prices" to unexpected("prices"),
            "TestAssetPricesQuery assets.2.listedAt" to unexpected("listedAt"),
        )
    }

    @Test
    fun `every reads row of the operations with lenses reads as the case says`() {
        val covered = Spec.cases.filter { it.operation in TestLenses.byOperation }
        assertEquals(TestLenses.byOperation.keys, covered.map { it.operation }.toSet(), "every lens has a case to read")
        val failures = ArrayList<String>()
        var rows = 0
        for (case in covered) {
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
                val rule = rules["${case.operation} ${row.path}"]
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

    /** Whether a lens's value is the row's: a mapped scalar compared as its type's value, an enum by its text. */
    private fun matches(actual: Any?, expected: Any?): Boolean = when {
        expected == null -> actual == null
        actual == null -> false
        expected is List<*> -> actual is List<*> && actual.size == expected.size && actual.indices.all { matches(actual[it], expected[it]) }
        actual is BigDecimal -> expected is String && DecimalConverter.parse(expected)?.compareTo(actual) == 0
        actual is Instant -> expected is String && InstantConverter.parse(expected) == actual
        actual is URI -> expected is String && UriConverter.parse(expected) == actual
        actual is GeneratedEnum -> expected is String && actual.scalarText == expected
        actual is Int -> expected is Long && expected == actual.toLong()
        actual is Double -> expected is Number && expected.toDouble() == actual
        else -> actual == expected
    }
}
