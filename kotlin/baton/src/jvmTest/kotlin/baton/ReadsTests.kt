package baton

import baton.spec.DateTimes
import baton.spec.Decimals
import baton.spec.TestNotesQuery
import baton.spec.TestProfileQuery
import baton.spec.TestStrictQuery
import baton.spec.Urls
import java.lang.reflect.InvocationTargetException
import java.math.BigDecimal
import java.net.URI
import java.time.Instant
import kotlin.reflect.KClass
import kotlin.reflect.KProperty1
import kotlin.reflect.KVisibility
import kotlin.reflect.full.memberProperties
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

        /**
         * The value at a row's path: a response key through the property of
         * its name, an index into a list. A `Result` reads as its value or as
         * absent, and a getter that throws a field's error reads as absent, as
         * a fragment that throws does.
         */
        fun walk(path: String): Any? {
            var current: Any? = data
            for (segment in path.split('.')) {
                current = when (current) {
                    null -> return null
                    is List<*> -> current.getOrElse(segment.toInt()) { fail("$path: no element $segment") }
                    else -> (Walker.field(current, segment) ?: fail("$path: ${current::class.simpleName} reads no field $segment")).value
                }
            }
            return current
        }
    }

    /**
     * A row's path over generated code: a response key is the Kotlin name of
     * the property that reads it, backticks and JVM names aside. A key the
     * lens does not read itself is read through what reads the same record:
     * a fragment's spread, an inline fragment's lens, an `@inline`
     * fragment's value.
     */
    private object Walker {
        /** What a property read: its value, null where it read as absent. */
        class Found(val value: Any?)

        fun field(owner: Any, key: String): Found? {
            val properties = properties(owner::class)
            properties[key]?.let { return Found(read(it, owner)) }
            var absent: Found? = null
            for (property in properties.values) {
                val inner = read(property, owner)
                if (inner == null) {
                    // A fragment that reads as absent, or throws, holds its
                    // fields absent: its class says which they are.
                    val fragment = fragmentClass(property)
                    if (fragment != null && declares(fragment, key)) absent = Found(null)
                    continue
                }
                if (!reachesTheSameRecord(owner, inner)) continue
                val found = field(inner, key) ?: continue
                if (found.value != null) return found
                absent = found
            }
            return absent
        }

        /** The public properties of [type] by name, but the anchor and the record's identity every lens has. */
        private fun properties(type: KClass<*>): Map<String, KProperty1<Any, *>> {
            @Suppress("UNCHECKED_CAST")
            return (type.memberProperties as Collection<KProperty1<Any, *>>)
                .filter { it.visibility == KVisibility.PUBLIC && it.name != "anchor" && it.name != "recordID" }
                .associateBy { it.name }
        }

        /** The fragment's class a property reads, a `Result` of one among them, or null for anything else. */
        private fun fragmentClass(property: KProperty1<Any, *>): KClass<*>? {
            var type = property.returnType
            if (type.classifier == Result::class) type = type.arguments.first().type ?: return null
            val classifier = type.classifier as? KClass<*> ?: return null
            return classifier.takeIf { isFragment(it.java) }
        }

        /** Whether [type], a fragment's class, reads [key] itself or through a fragment it spreads. */
        private fun declares(type: KClass<*>, key: String): Boolean {
            val properties = properties(type)
            if (key in properties) return true
            return properties.values.any { property -> fragmentClass(property)?.let { declares(it, key) } ?: false }
        }

        /** Whether [type] is a fragment's lens or value: a generated class at the top of its package. */
        private fun isFragment(type: Class<*>): Boolean = type.packageName == "baton.spec" && type.enclosingClass == null

        /** A property's value: a `Result` unwrapped, a failure or a thrown field error as absent. */
        private fun read(property: KProperty1<Any, *>, owner: Any): Any? {
            val value = try {
                property.get(owner)
            } catch (error: InvocationTargetException) {
                if (error.cause is FieldErrors || error.cause is RequiredFieldError) return null
                throw error.cause ?: error
            } catch (_: FieldErrors) {
                return null
            } catch (_: RequiredFieldError) {
                return null
            }
            return if (value is Result<*>) value.getOrNull() else value
        }

        /**
         * Whether [inner] reads the record [owner] reads: a fragment's lens or
         * value, a class of its own at the top of the package, or a nested
         * lens over the same record, an inline fragment's. A nested lens over
         * another record is a link's.
         */
        private fun reachesTheSameRecord(owner: Any, inner: Any): Boolean {
            val type = inner::class.java
            if (type.packageName != "baton.spec") return false
            if (isFragment(type)) return true
            return inner is Lens && owner is Lens && inner.anchor.record === owner.anchor.record
        }
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

    /** Whether a lens's value is the row's: a mapped scalar compared as its type's value, an enum by its text. */
    private fun matches(actual: Any?, expected: Any?): Boolean = when {
        expected == null -> actual == null
        actual == null -> false
        expected is List<*> -> actual is List<*> && actual.size == expected.size && actual.indices.all { matches(actual[it], expected[it]) }
        actual is BigDecimal -> expected is String && Decimals.parse(expected)?.compareTo(actual) == 0
        actual is Instant -> expected is String && DateTimes.parse(expected) == actual
        actual is URI -> expected is String && Urls.parse(expected) == actual
        actual is GeneratedEnum -> expected is String && actual.scalarText == expected
        actual is Int -> expected is Long && expected == actual.toLong()
        actual is Double -> expected is Number && expected.toDouble() == actual
        else -> actual == expected
    }
}
