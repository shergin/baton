package baton

import androidx.compose.runtime.snapshots.Snapshot
import baton.spec.Slots
import baton.spec.Types
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class StoreTests {
    private val header = Spec.case("rickandmorty/character-header-9")

    /** The header's response with the name changed, as a later fetch of the same character answers. */
    private val renamed = Spec.text(header.responses[0]).replace("\"Agency Director\"", "\"Agency Director Prime\"").encodeToByteArray()

    /** The header's response with the status changed, as another later fetch answers. */
    private val revived = Spec.text(header.responses[0]).replace("\"Dead\"", "\"Alive\"").encodeToByteArray()

    private fun commit(store: Store, case: Spec.Case, response: ByteArray): Int {
        val resolved = store.resolve(checkNotNull(case.plan), case.variables)
        return store.commit(Ingest.normalize(response, resolved, Store.ROOT_KEY))
    }

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

    /** The states a read of [slot] on [record] registers in a snapshot that observes its reads. */
    private fun statesRead(record: Record, slot: Slot): Set<Any> = statesRead { record.read(slot) }

    /** The states [writes] modifies in the global snapshot, as an apply observer hears them once the snapshot's changes are sent. */
    private fun statesModified(writes: () -> Unit): Set<Any> {
        val modified = HashSet<Any>()
        val observer = Snapshot.registerApplyObserver { states, _ -> modified.addAll(states) }
        try {
            writes()
            Snapshot.sendApplyNotifications()
        } finally {
            observer.dispose()
        }
        return modified
    }

    @Test
    fun `a commit that changes one field tells that field's readers alone`() {
        val store = Store()
        header.commit(store)
        val character = assertNotNull(store.existing("Character:9"))
        val name = Registry.slot(character.type, "name")
        val status = Registry.slot(character.type, "status")
        val nameStates = statesRead(character, name)
        val statusStates = statesRead(character, status)
        assertTrue(nameStates.isNotEmpty() && statusStates.isNotEmpty(), "a read registers the slot's channel")

        val changed = statesModified { assertEquals(1, commit(store, header, renamed), "the commit reports the one field it changed") }
        assertTrue(nameStates.all { it in changed }, "the name's readers are told")
        assertTrue(statusStates.none { it in changed }, "the status's readers are not")
        assertEquals(Value.String("Agency Director Prime"), character.peek(name))
    }

    @Test
    fun `a slot nobody read has no channel, so a commit modifies no snapshot state but the store's revision`() {
        val store = Store()
        val revision = statesRead { store.revision }
        val making = statesModified { header.commit(store) }
        assertEquals(revision, making, "a commit that makes the records modifies the revision alone")
        val renaming = statesModified { assertEquals(1, commit(store, header, renamed), "the name changed") }
        assertEquals(revision, renaming, "a commit that changes a field nobody read modifies the revision alone")
    }

    @Test
    fun `a slot that was read has a channel, and a commit modifies it only when it changes that slot`() {
        val store = Store()
        header.commit(store)
        val character = assertNotNull(store.existing("Character:9"))
        val name = statesRead(character, Registry.slot(character.type, "name"))
        assertTrue(name.isNotEmpty(), "a read makes the slot's channel and registers it")
        val revision = statesRead { store.revision }

        val statusChange = statesModified { assertEquals(1, commit(store, header, revived), "the status changed") }
        assertEquals(revision, statusChange, "a change to another field of the record modifies the revision alone")
        val sameAgain = statesModified { assertEquals(0, commit(store, header, revived), "nothing changed") }
        assertEquals(revision, sameAgain, "the same payload again modifies the revision alone")
        val nameChange = statesModified { assertEquals(2, commit(store, header, renamed), "the name and the status changed") }
        assertEquals(name + revision, nameChange, "a change to the name modifies the channel its read registered, and to the status, which nobody read, no state")
    }

    @Test
    fun `a response equal to what the store holds changes nothing`() {
        val store = Store()
        header.commit(store)
        assertEquals(0, commit(store, header, Spec.bytes(header.responses[0])))
    }

    @Test
    fun `a key the store rendered and the build named after is held at one slot and listed once`() {
        val probe = DynamicKey(Registry.type("Query"), "kotlinTwinProbe", listOf(KeyArgument("id", listOf(KeyPart.Variable("id")))))
        val variables = Variables(mapOf("id" to Variable.String("1")))
        val rendered = Plan(
            Selection(
                Registry.type("Query"),
                emptyList(),
                fields = listOf(PlanField.scalar("kotlinTwinProbe", StorageKey.Dynamic(probe), ScalarKind.STRING, list = false)),
            ),
        )
        val store = Store()
        val first = store.resolve(rendered, variables)
        val renderedSlot = first.fields.single().slot
        store.commit(Ingest.normalize("""{"data":{"kotlinTwinProbe":"first"}}""".encodeToByteArray(), first, Store.ROOT_KEY))
        assertTrue(renderedSlot.index < 0, "a rendered key is numbered by the store, apart from the build's")
        assertEquals(1, store.keys.count(Registry.type("Query")), "the store numbers the key it rendered")

        // The build names the same text as a constant after the store rendered it.
        val constant = Registry.slot(Registry.type("Query"), "kotlinTwinProbe(id:\"1\")")
        val named = Plan(
            Selection(
                Registry.type("Query"),
                emptyList(),
                fields = listOf(PlanField.scalar("kotlinTwinProbe", StorageKey.Fixed(constant), ScalarKind.STRING, list = false)),
            ),
        )
        val changed = store.commit(Ingest.normalize("""{"data":{"kotlinTwinProbe":"second"}}""".encodeToByteArray(), store.resolve(named, Variables.none), Store.ROOT_KEY))
        assertEquals(1, changed, "the key counts once though both of its slots were written")
        assertEquals(Value.String("second"), store.root.peek(renderedSlot), "a write to the constant lands in its twin")
        assertEquals(constant, store.resolve(rendered, variables).fields.single().slot, "a later rendering takes the constant's slot")

        val line = store.dump().lines().single { it.contains("\"client:root\"") }
        assertEquals(1, Regex("kotlinTwinProbe").findAll(line).count(), line)
        assertTrue(line.contains("\"kotlinTwinProbe(id:\\\"1\\\")\": \"second\""), line)
    }

    @Test
    fun `a number the keys freed goes to the next new text, the lowest first, and a kept text keeps its own`() {
        val keys = Keys()
        val query = Types.Query
        fun probe(term: String): Slot = keys.slot(query, "keysProbe(term:\"$term\")")
        val numbered = listOf("a", "b", "c", "d").map(::probe)
        assertEquals(listOf(0, 1, 2, 3), numbered.map { it.index.inv() }, "the store numbers new texts from zero")
        val (first, second, kept, fourth) = numbered
        val generation = keys.generation

        // The kept number sits above two freed ones, so they are holes the table keeps.
        assertEquals(listOf(first, second, fourth), keys.free(setOf(kept)))
        assertEquals(1, keys.count(query))
        assertEquals(generation + 1, keys.generation, "a free that freed numbers advances the generation once")
        assertEquals("", keys.text(first), "a freed number names no text")
        assertEquals("keysProbe(term:\"c\")", keys.text(kept))
        assertEquals(kept, probe("c"), "a kept text keeps its number")

        assertEquals(first, probe("e"), "the next new text takes the lowest freed number")
        assertEquals(second, probe("f"))
        assertEquals(fourth, probe("g"), "and once the holes are taken, the lowest number above the kept one")
        assertEquals("keysProbe(term:\"e\")", keys.text(first))

        assertEquals(emptyList<Slot>(), keys.free(setOf(first, second, kept, fourth)))
        assertEquals(generation + 1, keys.generation, "a free that freed nothing leaves the generation alone")
    }

    @Test
    fun `a text the build names as a constant takes the build's slot, which the store does not number`() {
        val keys = Keys()
        val constant = Slots.Character.name
        val slot = keys.slot(Types.Character, "name")
        assertEquals(constant, slot)
        assertTrue(slot.index >= 0, "the build's slots are dense")
        assertEquals(0, keys.count(Types.Character))
    }

    @Test
    fun `a store refuses a call from a thread other than the one that made it`() {
        val store = Store()
        val changes = Ingest.normalize(Spec.bytes(header.responses[0]), store.resolve(checkNotNull(header.plan), header.variables), Store.ROOT_KEY)
        var failure: Throwable? = null
        val thread = Thread { failure = runCatching { store.commit(changes) }.exceptionOrNull() }
        thread.start()
        thread.join()
        assertTrue(failure is IllegalStateException, "the commit fails off the store's thread, not with $failure")
        assertEquals(3, store.count, "nothing was written")
    }

    @Test
    fun `a request error writes nothing and says why`() {
        val store = Store()
        val resolved = store.resolve(checkNotNull(header.plan), header.variables)
        val error = assertFailsWith<GraphQLErrors> {
            Ingest.normalize("""{"data":null,"errors":[{"message":"no such character"}]}""".encodeToByteArray(), resolved, Store.ROOT_KEY)
        }
        assertEquals("no such character", error.errors.single().message)
    }

    @Test
    fun `a complete response that omits a field the operation selected is malformed`() {
        val store = Store()
        val resolved = store.resolve(checkNotNull(header.plan), header.variables)
        val response = """{"data":{"character":{"name":"Agency Director","id":"9"}}}""".encodeToByteArray()
        val error = assertFailsWith<IngestError> { Ingest.normalize(response, resolved, Store.ROOT_KEY, complete = true) }
        assertEquals(21, error.offset, "the offset is the object's opening brace")
    }

    @Test
    fun `floats are rendered as the contract's rule spells them`() {
        val spelled = listOf(1.0, -0.0, 0.0001, 0.00001, 1e16, 1.5e-7, 9007199254740992.0, 1e15, -2.5e-3, 123456789.125, 1e100)
            .map { Variable.renderDouble(it) }
        assertEquals(
            listOf("1.0", "-0.0", "0.0001", "1e-05", "1e+16", "1.5e-07", "9007199254740992.0", "1000000000000000.0", "-0.0025", "123456789.125", "1e+100"),
            spelled,
        )
    }
}
