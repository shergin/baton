package baton

import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import baton.spec.TestStreamedEpisodes
import baton.spec.TestStreamedNotes
import baton.testing.ScriptedTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * What a streamed list does that the cases and the script `streams` do not
 * pin: the shapes a part's items come in, the nulls an item placed past the
 * end leaves, the parts dropped, the stream cut short, the check under an
 * undated root, the streamed connection, the notifications per item and the
 * stale item. See `docs/decisions/a-streamed-list-grows-in-its-slot.md`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StreamTests {
    /**
     * An incremental response delivered by hand into [store], as the
     * environment's send loop delivers it: the first part committed, then
     * each later part's objects normalized, kept when they still fit, and
     * committed one by one, and its failed parts committed.
     */
    private class Streaming(val store: Store, operation: QueryOperation<*>) {
        val resolved = store.resolve(operation.type.plan, operation.variables)
        val data: Lens = operation.type.data(Anchor(store.root, Owner(operation.variables, store)))
        private val delivery = Delivery(store, resolved)

        fun first(path: String) {
            val first = Ingest.normalizeFirstPart(Spec.bytes(path), resolved, Store.ROOT_KEY, complete = true)
            store.commit(first.changes)
            delivery.committed(first.changes)
            delivery.announce(first.pending)
        }

        fun part(path: String) = part(Spec.bytes(path))

        fun part(bytes: ByteArray) {
            val part = Ingest.incremental(bytes)
            delivery.announce(part.pending)
            val objects = delivery.objects(part)
            val failures = delivery.failures(part)
            for (obj in objects) {
                val changes = obj.normalize()
                if (!delivery.fits(obj)) continue
                store.commit(changes)
                delivery.committed(changes)
            }
            for (failure in failures) store.commit(failure.changes)
        }
    }

    /** The keys of the records the list at [field] of the record [key] holds, a null element as null. */
    private fun Store.links(key: String, field: String): List<String?>? {
        val record = existing(key) ?: return null
        val value = record.peek(Registry.slot(record.type, field)) as? Value.Refs ?: return null
        return value.records.map { it?.key }
    }

    private fun episodes(data: Lens): List<String> =
        assertNotNull((data as TestStreamedEpisodes.Data).character).episode.map { it.name.orEmpty() }

    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher. */
    private fun TestScope.environment(transport: ScriptedTransport, store: Store = Store()): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, store, dispatcher, dispatcher)
    }

    /** The parts the log heard dropped, leaving the commits aside. */
    private fun List<LogEvent>.dropped(): List<LogEvent> = filterIsInstance<LogEvent.PartDropped>()

    private fun json(bytes: ByteArray): Any? = Json.parse(bytes.decodeToString())

    @Test
    fun `a part's items parse in the June 2023 shape by path and label and in the 2024 shape by id, and Relay's single item parses as data`() {
        val june = Ingest.incremental(Spec.bytes("tests/character-streamed-3.json")).items.single()
        assertEquals(listOf(PathSegment.Name("character"), PathSegment.Name("episode"), PathSegment.Index(2)), june.path)
        assertEquals("TestStreamedEpisodes\$stream\$episodes", june.label)
        assertNull(june.id)
        assertEquals(listOf<Any?>(mapOf("id" to "3", "name" to "Anatomy Park")), assertNotNull(june.items).map { json(it) })

        val latest = Ingest.incremental(Spec.bytes("tests/character-streamed-2-pending.json"))
        val item = latest.items.single()
        assertNull(item.path)
        assertEquals("0", item.id)
        assertEquals(
            listOf<Any?>(mapOf("id" to "2", "name" to "Lawnmower Dog"), mapOf("id" to "3", "name" to "Anatomy Park")),
            assertNotNull(item.items).map { json(it) },
        )
        assertEquals(listOf("0"), latest.completed.map { it.id })

        val relay = Ingest.incremental(Spec.bytes("tests/character-streamed-2.json")).items.single()
        assertNull(relay.items, "Relay's shape carries its one item as data")
        assertEquals(mapOf("id" to "2", "name" to "Lawnmower Dog"), json(relay.data))
        assertEquals(PathSegment.Index(1), relay.path?.last())
    }

    @Test
    fun `an item placed beyond the list's end leaves nulls the lens skips, and the item that fills the hole reads in its order`() {
        val streaming = Streaming(Store(), TestStreamedEpisodes(id = "1"))
        streaming.first("tests/character-streamed-1.json")
        streaming.part("tests/character-streamed-3-first.json")
        assertEquals(listOf("Episode:1", null, "Episode:3"), streaming.store.links("Character:1", "episode"))
        assertEquals(listOf("Pilot", "Anatomy Park"), episodes(streaming.data))

        streaming.part("tests/character-streamed-2.json")
        assertEquals(listOf("Episode:1", "Episode:2", "Episode:3"), streaming.store.links("Character:1", "episode"))
        assertEquals(listOf("Pilot", "Lawnmower Dog", "Anatomy Park"), episodes(streaming.data))
    }

    @Test
    fun `a part naming a field the plan does not have or does not stream under its label is dropped and logged`() {
        val store = Store()
        val events = ArrayList<LogEvent>()
        store.log = { events.add(it) }
        val streaming = Streaming(store, TestStreamedEpisodes(id = "1"))
        streaming.first("tests/character-streamed-1.json")
        val before = store.dump()

        streaming.part("tests/character-streamed-stray.json")
        assertEquals(listOf<LogEvent>(LogEvent.PartDropped("character.nonexistent.0")), events.dropped())
        assertEquals(before, store.dump(), "a stray part writes nothing")

        // The streamed field under a label that is not its stream's: the plan does not stream it so.
        events.clear()
        val relabeled = Spec.text("tests/character-streamed-2.json").replace("\$stream\$episodes", "\$stream\$elsewhere")
        streaming.part(relabeled.encodeToByteArray())
        assertEquals(listOf<LogEvent>(LogEvent.PartDropped("character.episode.1")), events.dropped())
        assertEquals(before, store.dump())
    }

    @Test
    fun `an item of a list this response never wrote is dropped and logged`() {
        val store = Store()
        val events = ArrayList<LogEvent>()
        store.log = { events.add(it) }
        val operation = TestStreamedEpisodes(id = "1")
        val resolved = store.resolve(operation.type.plan, operation.variables)
        // Another response wrote the list: a delivery that did not commit it has no stream there.
        store.commit(Ingest.normalize(Spec.bytes("tests/character-streamed-1.json"), resolved, Store.ROOT_KEY))
        val delivery = Delivery(store, resolved)
        assertTrue(delivery.objects(Ingest.incremental(Spec.bytes("tests/character-streamed-2.json"))).isEmpty())
        assertEquals(listOf<LogEvent>(LogEvent.PartDropped("character.episode.1")), events.dropped())
        assertEquals(listOf<String?>("Episode:1"), store.links("Character:1", "episode"))
    }

    @Test
    fun `an item whose list a payload changed before it lands is dropped, and the list keeps the payload's`() {
        val store = Store()
        val events = ArrayList<LogEvent>()
        store.log = { events.add(it) }
        val streaming = Streaming(store, TestStreamedEpisodes(id = "3"))
        streaming.first("tests/character-streamed-summer-1.json")
        store.commit(Ingest.normalize(Spec.bytes("tests/character-streamed-summer-payload.json"), streaming.resolved, Store.ROOT_KEY))
        assertEquals(listOf<String?>("Episode:6"), store.links("Character:3", "episode"))

        streaming.part("tests/character-streamed-summer-2.json")
        assertEquals(listOf<LogEvent>(LogEvent.PartDropped("character.episode.1")), events.dropped())
        assertEquals(listOf<String?>("Episode:6"), store.links("Character:3", "episode"), "the list keeps the payload's")
        assertNull(store.existing("Episode:2"), "the stale item's object is not committed either")
        assertEquals(listOf("Rick Potion #9"), episodes(streaming.data))
    }

    @Test
    fun `a streamed edge reaches the connection, and the deferred page info gives the connection its end cursor`() {
        val streaming = Streaming(Store(), TestStreamedNotes(id = "1"))
        streaming.first("tests/notes-streamed-1.json")
        val notes = { assertNotNull((streaming.data as TestStreamedNotes.Data).character).notes }
        assertEquals(listOf<String?>("n1"), notes().nodes.map { it.id })

        streaming.part("tests/notes-streamed-2.json")
        assertEquals(listOf<String?>("n1", "n2"), notes().nodes.map { it.id })
        assertEquals(listOf("c1", "c2"), notes().edges?.map { it.cursor })
        assertEquals(
            listOf("Character:1:notes(first:2):edges:0", "Character:1:notes(first:2):edges:1"),
            streaming.store.links("Character:1:__TestStreamedNotes_notes_connection", "edges"),
        )

        streaming.part("tests/notes-streamed-3.json")
        assertEquals("c2", notes().pageInfo.endCursor)
        assertTrue(notes().pageInfo.hasNextPage)
        assertTrue(notes().hasNext, "the connection's page info is the deferred page info merged")
        assertEquals(listOf<String?>("n1", "n2"), notes().nodes.map { it.id })
    }

    @Test
    fun `a stream the transport ends after a part that says more follow fails the fetch as malformed and leaves the root undated`() = runTest {
        val transport = ScriptedTransport()
        transport.drive("TestStreamedEpisodes")
        val environment = environment(transport)
        val events = ArrayList<LogEvent>()
        environment.log = { events.add(it) }
        val handle = environment.handle(TestStreamedEpisodes(id = "1"))
        val hold = handle.retain()
        runCurrent()
        val stream = transport.driven.single()
        stream.send(Spec.bytes("tests/character-streamed-1.json"))
        runCurrent()
        assertEquals(Fetch.InFlight, handle.fetch)
        assertTrue(handle.isRefreshing, "the first part shows while the stream runs")

        stream.complete()
        runCurrent()
        val failed = assertIs<Fetch.Failed>(handle.fetch)
        assertIs<Failure.Malformed>(failed.failure)
        assertNull(handle.fetchTime, "nothing dates the root")
        assertTrue(LogEvent.FetchFailed("TestStreamedEpisodes", LogEvent.FailureKind.MALFORMED) in events, "$events")
        assertEquals(listOf("Pilot"), episodes(assertIs<Phase.Ready<TestStreamedEpisodes.Data>>(handle.phase).data))
        hold.release()
        environment.end()
    }

    @Test
    fun `a store-or-network handle attached while a stream's root is undated fetches, and one attached after the stream completed does not`() = runTest {
        val store = Store()
        val operation = TestStreamedEpisodes(id = "1")
        val resolved = store.resolve(operation.type.plan, operation.variables)
        // The first part is in the store, the list holding its first item, and nothing dated the root.
        store.commit(Ingest.normalizeFirstPart(Spec.bytes("tests/character-streamed-1.json"), resolved, Store.ROOT_KEY, complete = true).changes)
        val transport = ScriptedTransport()
        transport.drive("TestStreamedEpisodes")
        val environment = environment(transport, store)
        val handle = environment.handle(operation, FetchPolicy.STORE_OR_NETWORK)
        val hold = handle.retain()
        runCurrent()
        assertEquals(1, transport.requestCount, "a streamed list under an undated root is not held")
        assertIs<Phase.Ready<*>>(handle.phase)

        val stream = transport.driven.single()
        stream.send(Spec.bytes("tests/character-streamed-1.json"))
        stream.send(Spec.bytes("tests/character-streamed-2.json"))
        stream.send(Spec.bytes("tests/character-streamed-3.json"))
        stream.complete()
        runCurrent()
        assertEquals(Fetch.Idle, handle.fetch)
        assertNotNull(handle.fetchTime, "the stream completed and dated the root")

        val again = environment.handle(operation, FetchPolicy.STORE_OR_NETWORK)
        val second = again.retain()
        runCurrent()
        assertEquals(1, transport.requestCount, "the completed stream's list is held")
        assertEquals(listOf("Pilot", "Lawnmower Dog", "Anatomy Park"), episodes(assertIs<Phase.Ready<TestStreamedEpisodes.Data>>(again.phase).data))
        second.release()
        hold.release()
        environment.end()
    }

    @Test
    fun `a streamed list observed through a snapshot is notified once per item`() = runTest {
        val transport = ScriptedTransport()
        transport.drive("TestStreamedEpisodes")
        val main = StandardTestDispatcher(testScheduler)
        val environment = Environment(transport, null, Store(), main, main)
        val handle = environment.handle(TestStreamedEpisodes(id = "1"))
        val hold = handle.retain()
        runCurrent()
        val stream = transport.driven.single()
        stream.send(Spec.bytes("tests/character-streamed-1.json"))
        runCurrent()

        val seen = ArrayList<List<String>>()
        backgroundScope.launch(main) {
            snapshotFlow { (handle.phase as? Phase.Ready<TestStreamedEpisodes.Data>)?.data?.let { episodes(it) } }.collect { names ->
                if (names != null) seen += names
            }
        }
        runCurrent()
        val character = assertNotNull(environment.store.existing("Character:1"))
        val slot = Registry.slot(character.type, "episode")
        val listStates = HashSet<Any>()
        val reading = Snapshot.takeSnapshot { listStates.add(it) }
        try {
            reading.enter { character.read(slot) }
        } finally {
            reading.dispose()
        }
        assertTrue(listStates.isNotEmpty(), "a read registers the list's channel")
        var notifications = 0
        val observer = Snapshot.registerApplyObserver { changed, _ -> if (changed.any { it in listStates }) notifications += 1 }
        try {
            stream.send(Spec.bytes("tests/character-streamed-2.json"))
            runCurrent()
            Snapshot.sendApplyNotifications()
            assertEquals(1, notifications, "the first streamed item notifies the list once")
            stream.send(Spec.bytes("tests/character-streamed-3.json"))
            runCurrent()
            Snapshot.sendApplyNotifications()
            runCurrent()
            assertEquals(2, notifications, "and the second once more")
        } finally {
            observer.dispose()
        }
        assertEquals(
            listOf(listOf("Pilot"), listOf("Pilot", "Lawnmower Dog"), listOf("Pilot", "Lawnmower Dog", "Anatomy Park")),
            seen,
            "the observed list grows by one item per part",
        )
        hold.release()
        environment.end()
    }
}
