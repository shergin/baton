package baton

import androidx.compose.runtime.snapshots.Snapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The readers' rules that no `reads` row holds: what a read registers, reports and drops. */
class LensTests {
    /** A store with [case]'s responses committed, logging into [events] from then on. */
    private class Session(vararg cases: String) {
        val store = Store()
        val events = ArrayList<LogEvent>()

        init {
            for (name in cases) Spec.case(name).commit(store)
            store.log = { events.add(it) }
        }

        fun commit(case: Spec.Case, response: String) {
            val resolved = store.resolve(checkNotNull(case.plan), case.variables)
            store.commit(Ingest.normalize(response.encodeToByteArray(), resolved, Store.rootKey(case.kind)))
            events.clear()
        }

        fun anchor(kind: OperationKind, variables: Variables): Anchor = Anchor(store.root(kind), Owner(variables, store))
    }

    private val one = Variables(mapOf("id" to Variable.String("1")))

    /** The states [read] registers in a snapshot that observes its reads. */
    private fun statesRead(read: () -> Unit): Set<Any> {
        val states = HashSet<Any>()
        val snapshot = Snapshot.takeSnapshot { states.add(it) }
        try {
            snapshot.enter(read)
        } finally {
            snapshot.dispose()
        }
        return states
    }

    @Test
    fun `a write to one field tells the readers of that field through a lens and no other`() {
        val session = Session("tests/character-deferred-1")
        val profile = assertNotNull(TestProfileQuery.Data(session.anchor(OperationKind.QUERY, one)).character?.testProfile)
        val nameStates = statesRead { profile.name }
        val statusStates = statesRead { profile.status }
        assertTrue(nameStates.isNotEmpty() && statusStates.isNotEmpty(), "a read through a lens registers its slot")

        val changed = HashSet<Any>()
        val observer = Snapshot.registerApplyObserver { states, _ -> changed.addAll(states) }
        try {
            val case = Spec.case("tests/character-deferred-1")
            session.commit(case, Spec.text(case.responses[0]).replace("\"Rick Sanchez\"", "\"Rick Prime\""))
            Snapshot.sendApplyNotifications()
        } finally {
            observer.dispose()
        }
        assertTrue(nameStates.all { it in changed }, "the name's readers are told")
        assertTrue(statusStates.none { it in changed }, "the status's readers are not")
        assertEquals("Rick Prime", profile.name)
    }

    @Test
    fun `a required scalar reads a zero value and reports the null or the miss once`() {
        val session = Session()
        val strict = Spec.case("tests/character-name-hidden")
        session.commit(strict, """{"data":{"character":{"id":"1","name":"Rick Sanchez","species":null}}}""")
        val character = assertNotNull(TestStrictQuery.Data(session.anchor(OperationKind.QUERY, one)).character)
        assertEquals("", character.species)
        assertEquals(listOf<LogEvent>(LogEvent.Unexpected("Character", "species")), session.events, "a null in a non-null field is unexpected")

        // A character the store holds without `species`: the read is a miss.
        val notes = Session("tests/notes-page-1")
        val fetched = assertNotNull(TestStrictQuery.Data(notes.anchor(OperationKind.QUERY, one)).character)
        assertEquals("", fetched.species)
        assertEquals(listOf<LogEvent>(LogEvent.Missing("Character", "species")), notes.events)
        val totalCount = assertNotNull(TestNotesQuery.Data(notes.anchor(OperationKind.QUERY, one)).character).testNotes.notes.totalCount
        assertEquals(5, totalCount)
    }

    @Test
    fun `a deleted record reads as null through a link and is dropped from a list and from the nodes`() {
        val session = Session("tests/notes-page-1", "tests/remove-note-n2")
        val notes = assertNotNull(TestNotesQuery.Data(session.anchor(OperationKind.QUERY, one)).character).testNotes.notes
        val edges = assertNotNull(notes.edges)
        assertEquals(2, edges.size, "the edges are live; the node behind the second is not")
        assertEquals("n1", edges[0].node?.id)
        assertNull(edges[1].node, "a link to a deleted record reads as null")
        assertEquals(listOf("n1"), notes.nodes.map { it.id })

        val store = Store()
        val list = notesList(store, """[{"id":"n1","text":"a"},{"id":"n2","text":"b"},null,{"id":"n3","text":"c"}]""")
        Spec.case("tests/remove-note-n2").commit(store)
        val texts = Anchor(store.root, Owner(Variables.none, store)).requiredList(list, ::Note).map { it.text }
        assertEquals(listOf("a", "c"), texts, "null elements and deleted records are dropped")
    }

    @Test
    fun `an element whose required field is null is dropped by keep`() {
        val store = Store()
        val events = ArrayList<LogEvent>()
        val list = notesList(store, """[{"id":"n1","text":"a"},{"id":"n2","text":null},{"id":"n3","text":"c"}]""")
        store.log = { events.add(it) }
        val anchor = Anchor(store.root, Owner(Variables.none, store))
        val kept = anchor.requiredList(list, ::Note) { it.hasValue(Slots.Note.text, "notes.text", log = true) }
        assertEquals(listOf("n1", "n3"), kept.map { it.id })
        assertEquals(listOf<LogEvent>(LogEvent.RequiredFieldMissing("Note", "notes.text")), events, "a LOG action logs the path")
        assertEquals(3, anchor.requiredList(list, ::Note).size, "without keep every live element stays")
    }

    @Test
    fun `a non-null link without a record reads the placeholder's zero values and reports the link once`() {
        val session = Session("tests/character-origin-null")
        val character = assertNotNull(TestProfileQuery.Data(session.anchor(OperationKind.QUERY, one)).character)
        // The fragment is unsatisfied, so the spread is null; its lens built by hand reads what a view under it would.
        assertNull(character.testProfile)
        session.events.clear()
        val profile = TestProfile_character(character.anchor.entering())
        val origin = profile.origin
        assertEquals("client:placeholder:Location", origin.anchor.record.key)
        assertNull(origin.name)
        assertEquals("", origin.anchor.requiredString(Slots.Location.name))
        assertEquals(0, origin.anchor.requiredInt(Slots.Location.id))
        assertEquals(false, origin.anchor.requiredBool(Slots.Location.id))
        assertSame(origin.anchor.record, origin.anchor.requiredLinked(Slots.Location.id, Types.Location).record, "a non-null link below the placeholder reads the store's placeholder")
        assertEquals(listOf<LogEvent>(LogEvent.Unexpected("Character", "origin")), session.events, "the link alone is reported")
        assertSame(origin.anchor.record, profile.origin.anchor.record, "one placeholder per type per store")
        assertTrue("client:placeholder:Location" !in session.store.recordsByKey(), "the placeholder is never among the store's records")
    }

    @Test
    fun `a spread with arguments binds its child owner once per site`() {
        val store = Store()
        val owner = Owner(one, store)
        val site = ArgumentSite()
        var calls = 0
        val values = { calls += 1; mapOf("count" to Variable.Int(2), "cursor" to null) }
        val bound = owner.binding(site, values)
        assertSame(bound, owner.binding(site, values))
        assertEquals(1, calls, "the arguments are read once per site")
        assertEquals(Variables(mapOf("id" to Variable.String("1"), "count" to Variable.Int(2), "cursor" to Variable.Null)), bound.variables)
        assertNotSame(bound, owner.binding(ArgumentSite(), values), "another site binds its own")

        val session = Session("tests/notes-page-1")
        val character = assertNotNull(TestNotesQuery.Data(session.anchor(OperationKind.QUERY, one)).character)
        assertSame(character.testNotes.anchor.owner, character.testNotes.anchor.owner)
        assertEquals(character.testNotes, character.testNotes, "a lens is equal by its anchor")
    }

    @Test
    fun `a key the store never met reads as missing and writes nothing`() {
        val session = Session("tests/notes-page-1")
        val before = session.store.dump()
        val two = Variables(mapOf("id" to Variable.String("2")))
        assertNull(TestNotesQuery.Data(session.anchor(OperationKind.QUERY, two)).character)
        assertEquals(listOf<LogEvent>(LogEvent.Missing("Query", "character(id:\"2\")")), session.events)
        assertEquals(before, session.store.dump())
    }

    @Test
    fun `a read off the store's thread fails`() {
        val session = Session("tests/notes-page-1")
        val anchor = session.anchor(OperationKind.QUERY, one)
        val slot = anchor.owner.slot(Slots.Query.character_bca4f9)
        var failure: Throwable? = null
        val thread = Thread { failure = runCatching { anchor.linked(slot) }.exceptionOrNull() }
        thread.start()
        thread.join()
        assertTrue(failure is IllegalStateException, "the read fails off the store's thread, not with $failure")
    }

    @Test
    fun `an enum reads a value the build does not know as its undeclared case, and a null where non-null as an empty one`() {
        val session = Session("tests/lists-statuses")
        val lists = assertNotNull(TestSetStatuses.Data(session.anchor(OperationKind.MUTATION, Variables.none)).setLists).anchor
        assertEquals(listOf(Status.ALIVE, Status.Undeclared("GHOST"), null, Status.DEAD), lists.nullableEnumValues(Slots.ListsPayload.statuses, Status::of))
        assertEquals(listOf(Status.ALIVE, Status.Undeclared("GHOST"), Status.DEAD), lists.requiredEnumValues(Slots.ListsPayload.statuses, Status::of))
        assertEquals(listOf<LogEvent>(LogEvent.Unexpected("ListsPayload", "statuses")), session.events, "the null a non-null list cannot hold is reported once")
        session.events.clear()
        val missing = lists.requiredEnumValue(Slots.ListsPayload.counts, Status::of)
        assertEquals(Status.Undeclared(""), missing)
        assertFailsWith<IndexOutOfBoundsException> { LensList.empty<Note>()[0] }
    }

    /** A note read by hand over a plain list of notes. */
    private class Note(anchor: Anchor) : TestLens(anchor) {
        val id: String? get() = anchor.string(Slots.Note.id)
        val text: String? get() = anchor.string(Slots.Note.text)

        override fun field(key: String): Any? = unknown(key)
    }

    /** Commits [notes] as a root field `kotlinNotes`, a plural link to notes keyed by id, and returns its slot. */
    private fun notesList(store: Store, notes: String): Slot {
        val slot = Registry.slot(Types.Query, "kotlinNotes")
        val plan = Plan(
            Selection(
                Types.Query,
                emptyList(),
                fields = listOf(
                    PlanField.linked(
                        "kotlinNotes",
                        StorageKey.Fixed(slot),
                        plural = true,
                        selection = Selection(
                            Types.Note,
                            listOf("id"),
                            fields = listOf(
                                PlanField.scalar("id", StorageKey.Fixed(Slots.Note.id), ScalarKind.STRING, list = false),
                                PlanField.scalar("text", StorageKey.Fixed(Slots.Note.text), ScalarKind.STRING, list = false),
                            ),
                        ),
                    ),
                ),
            ),
        )
        val response = """{"data":{"kotlinNotes":$notes}}""".encodeToByteArray()
        store.commit(Ingest.normalize(response, store.resolve(plan, Variables.none), Store.ROOT_KEY))
        return slot
    }
}
