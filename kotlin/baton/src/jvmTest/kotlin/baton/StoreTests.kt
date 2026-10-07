package baton

import androidx.compose.runtime.snapshots.Snapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class StoreTests {
    private val header = Spec.case("rickandmorty/character-header-9")

    /** The header's response with the name changed, as a later fetch of the same character answers. */
    private val renamed = """
        {"data":{"character":{"name":"Agency Director Prime","status":"Dead","species":"Human","image":"https://rickandmortyapi.com/api/character/avatar/9.jpeg","origin":{"name":"Earth (Replacement Dimension)","id":"20"},"id":"9"}}}
    """.trimIndent().encodeToByteArray()

    private fun commit(store: Store, case: Spec.Case, response: ByteArray): Int {
        val resolved = store.resolve(checkNotNull(case.plan), case.variables)
        return store.commit(Ingest.normalize(response, resolved, Store.ROOT_KEY))
    }

    /** The states a read of [slot] on [record] registers in a snapshot that observes its reads. */
    private fun statesRead(record: Record, slot: Slot): Set<Any> {
        val read = HashSet<Any>()
        val snapshot = Snapshot.takeSnapshot { read.add(it) }
        try {
            snapshot.enter { record.read(slot) }
        } finally {
            snapshot.dispose()
        }
        return read
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
        assertTrue(nameStates.isNotEmpty() && statusStates.isNotEmpty(), "a read registers the slot's cell")

        val changed = HashSet<Any>()
        val observer = Snapshot.registerApplyObserver { states, _ -> changed.addAll(states) }
        try {
            assertEquals(1, commit(store, header, renamed), "the commit reports the one field it changed")
            Snapshot.sendApplyNotifications()
        } finally {
            observer.dispose()
        }
        assertTrue(nameStates.all { it in changed }, "the name's readers are told")
        assertTrue(statusStates.none { it in changed }, "the status's readers are not")
        assertEquals(Value.String("Agency Director Prime"), character.peek(name))
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
