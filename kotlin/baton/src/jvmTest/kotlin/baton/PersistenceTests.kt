package baton

import baton.spec.Fixture
import baton.spec.TestAssetPricesQuery
import baton.spec.TestHeaderQuery
import baton.spec.TestNoteCounts
import baton.spec.TestSecrets
import baton.testing.RecordedTransport
import baton.testing.SilentTransport
import java.io.File
import java.util.Collections
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest

/**
 * The image, launch after launch over one file, as a device runs an app:
 * each launch is an environment over a new store and a new `Persistence`
 * on the file, ended before the next is made. Mirrors the Swift runtime's
 * persistence tests, `swift/Tests/BatonTests/PersistenceTests.swift`.
 */
class PersistenceTests {
    private val image = TemporaryImage()

    @AfterTest
    fun deleteTheImage() {
        image.delete()
    }

    /** An environment over the image, as a launch of the app makes one. */
    private fun TestScope.launch(
        transport: Transport = SilentTransport(),
        path: String = image.path,
        version: String = "",
        sizeLimit: Int = 64 shl 20,
    ): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(Persistence(path, version, sizeLimit)), dispatcher, dispatcher)
    }

    /** Commits an operation's recorded response through its own plan, as a fetch would. */
    private fun commit(environment: Environment, operation: QueryOperation<*>, response: String) {
        val store = environment.store
        store.commit(Ingest.normalize(Spec.bytes(response), store.resolve(operation.type.plan, operation.variables), Store.ROOT_KEY))
    }

    /** Commits the fixture, waits for the image to write it and ends the launch. */
    private suspend fun seed(environment: Environment) {
        commit(environment, Fixture(page = 1), "rickandmorty/characters-page-1.json")
        environment.end()
    }

    /** The data of a handle the store answers without the network, or null when it cannot. */
    private fun <Data : Lens> stored(operation: QueryOperation<Data>, environment: Environment): Data? {
        val handle = environment.handle(operation, FetchPolicy.STORE_ONLY)
        return (handle.phase as? Phase.Ready)?.data
    }

    /** The first column of the first row a query of the image returns, as an integer; null for no row or a null. */
    private fun integer(sql: String, path: String = image.path): Long? {
        val connection = imageDriver().open(path)
        try {
            return connection.prepare(sql).use { statement ->
                if (!statement.step() || statement.isNull(0)) null else statement.getLong(0)
            }
        } finally {
            connection.close()
        }
    }

    @Test
    fun `a second launch reads the fixture from the image when its handle is made, with no network, and agrees with the first`() = runTest {
        val first = launch()
        commit(first, Fixture(page = 1), "rickandmorty/characters-page-1.json")
        val names = stored(Fixture(page = 1), first)?.characters?.results?.map { it.name }
        assertNotNull(names)
        first.end()

        val second = launch()
        assertEquals(3, second.store.count, "nothing is in memory before a handle asks")
        val data = assertNotNull(stored(Fixture(page = 1), second), "the image answers the handle")
        assertEquals(901, second.store.count, "898 entities and three roots, as the first launch held")
        assertEquals(898, second.store.hydratedRecords)
        assertEquals(names, data.characters?.results?.map { it.name })
        assertEquals(826, data.characters?.info?.count)
        assertEquals(null, data.characters?.info?.prev, "a null survives as a null")

        // The same question again is answered by memory alone.
        assertEquals(Answer.IMAGE, second.store.check(second.store.resolve(Fixture.plan, Fixture(page = 1).variables)), "data the image filled is the image's")
        assertEquals(898, second.store.hydratedRecords)
        second.end()
    }

    @Test
    fun `an image written under another version starts again, and the next launch under the first finds nothing`() = runTest {
        seed(launch())
        val upgraded = launch(version = "2")
        assertEquals(null, stored(Fixture(page = 1), upgraded), "the rows of another version are not read")
        upgraded.end()
        val back = launch()
        assertEquals(null, stored(Fixture(page = 1), back), "the rows went with the version")
        back.end()
        assertEquals(0L, integer("SELECT count(*) FROM records"))
    }

    @Test
    fun `an image over its size limit at open evicts the launches before the last and keeps the last launch's rows`() = runTest {
        // The assets alone, measured on a file of their own.
        val alone = TemporaryImage()
        try {
            val assetsOnly = launch(path = alone.path)
            commit(assetsOnly, TestAssetPricesQuery(), "tests/asset-prices.json")
            assetsOnly.end()
            val assetsSize = File(alone.path).length()

            seed(launch())
            val second = launch()
            commit(second, TestAssetPricesQuery(), "tests/asset-prices.json")
            second.end()
            val afterSecond = File(image.path).length()
            assertTrue(afterSecond > assetsSize, "the first launch's rows take room the second's alone do not")

            val third = launch(sizeLimit = (assetsSize + (afterSecond - assetsSize) / 2).toInt())
            assertEquals(3, stored(TestAssetPricesQuery(), third)?.assets?.size, "the last launch's rows stay")
            assertEquals(null, stored(Fixture(page = 1), third), "the launch before it went")
            third.end()
            assertTrue(File(image.path).length() < afterSecond, "the evicted rows gave their space back")
            assertEquals(3L, integer("SELECT value FROM meta WHERE key = 'generation'"), "the file was kept, not made again")
        } finally {
            alone.delete()
        }
    }

    @Test
    fun `an image whose last launch's rows alone are over its size limit evicts them all and starts again`() = runTest {
        seed(launch())
        val size = File(image.path).length()
        assertTrue(size > 4096)
        val small = launch(sizeLimit = 4096)
        assertEquals(null, stored(Fixture(page = 1), small))
        small.end()
        assertTrue(File(image.path).length() < size, "the file was deleted and made again")
        assertEquals(1L, integer("SELECT value FROM meta WHERE key = 'generation'"), "the file made again counts its first launch")
    }

    @Test
    fun `a flushed image holds no record of a transient type and no cell, name or stamp of a transient root field, and keeps the record beside them`() = runTest {
        val operation = TestSecrets(code = "x")
        val environment = launch(RecordedTransport(mapOf("TestSecrets" to Spec.bytes("tests/secrets.json"))))
        environment.fetch(operation)
        val data = operation.type.data(Anchor(environment.store.root, Owner(operation.variables, environment.store)))
        assertEquals("where the citadel is", data.secrets?.get(1)?.body, "memory reads the transient root field")
        environment.end()

        assertEquals(0L, integer("SELECT count(*) FROM records WHERE key LIKE 'Secret:%'"))
        assertEquals(0L, integer("SELECT count(*) FROM root WHERE field LIKE 'secrets%'"))
        assertEquals(0L, integer("SELECT count(*) FROM names WHERE name LIKE 'secrets(%'"))
        assertEquals(0L, integer("SELECT count(*) FROM fetches"))
        assertEquals(1L, integer("SELECT count(*) FROM records WHERE key = 'Character:1'"))
        assertEquals(1L, integer("SELECT count(*) FROM root WHERE field LIKE 'character(%'"))

        val relaunched = launch()
        assertEquals(Answer.MISS, relaunched.store.check(relaunched.store.resolve(TestSecrets.plan, operation.variables)), "a relaunch misses and loads")
        relaunched.end()
    }

    @Test
    fun `a name no row uses any more is forgotten with the rows at a later launch's first batch, and its id is used again`() = runTest {
        val first = launch()
        commit(first, TestNoteCounts(page = 1, count = 90), "tests/note-counts-1.json")
        first.end()
        assertEquals(1L, integer("SELECT count(*) FROM names WHERE name = 'notes(first:90)'"), "the rows name the rendered key")
        val highest = assertNotNull(integer("SELECT max(id) FROM names"))

        // Two launches that open the image and read nothing, so the first
        // launch's rows age out at the next launch's first batch.
        for (launch in 0 until 2) {
            val idle = launch()
            idle.store.persistence?.flush()
            idle.end()
        }
        val fourth = launch()
        commit(fourth, TestNoteCounts(page = 1, count = 88), "tests/note-counts-1.json")
        fourth.store.persistence?.flush()
        assertEquals(0L, integer("SELECT count(*) FROM names WHERE name = 'notes(first:90)'"), "the name went with the rows that used it")
        val reused = assertNotNull(integer("SELECT id FROM names WHERE name = 'notes(first:88)'"))
        assertTrue(reused < highest, "the new name took an id the sweep freed")
        fourth.end()

        val fifth = launch()
        val data = assertNotNull(stored(TestNoteCounts(page = 1, count = 88), fifth))
        assertEquals(listOf(3, 0), data.characters?.results?.map { it.recent.totalCount }, "the rows written after the sweep read back")
        fifth.end()
    }

    @Test
    fun `a persistent environment logs the image opened at most once, before every write, and each write with the batches it landed`() = runTest {
        val heard = Collections.synchronizedList(ArrayList<LogEvent>())
        val environment = launch(RecordedTransport(mapOf("TestHeaderQuery" to Spec.bytes("tests/character-header-5.json"))))
        environment.log = { heard.add(it) }
        environment.fetch(TestHeaderQuery(id = "5"))
        environment.store.persistence?.flush()
        environment.end()

        val events = heard.toList().filter { it == LogEvent.ImageOpened || it is LogEvent.ImageWritten || it == LogEvent.ImageUnavailable || it == LogEvent.ImageWriteFailed }
        // The writer may open the file before the log is set, so the open is heard once at most.
        assertTrue(events.count { it == LogEvent.ImageOpened } <= 1, "$events")
        val opened = events.indexOf(LogEvent.ImageOpened)
        val written = events.withIndex().filter { it.value is LogEvent.ImageWritten }
        assertTrue(written.isNotEmpty(), "$events")
        assertTrue(written.all { it.index > opened }, "the open comes before every write: $events")
        assertTrue(written.all { (it.value as LogEvent.ImageWritten).batches >= 1 }, "an empty drain logs no write: $events")
        assertFalse(LogEvent.ImageUnavailable in events)
        assertFalse(LogEvent.ImageWriteFailed in events)
    }

    @Test
    fun `removeAll deletes an image and the work queued before it, and leaves a database of another kind alone`() = runTest {
        seed(launch())
        val leaving = launch()
        assertNotNull(stored(Fixture(page = 1), leaving))
        val persistence = assertNotNull(leaving.store.persistence)
        persistence.flush()
        // Held, so the commit is queued when the removal comes.
        persistence.holdingTheWriter {
            commit(leaving, TestAssetPricesQuery(), "tests/asset-prices.json")
            persistence.removeAll()
        }
        assertFalse(File(image.path).exists(), "the file is gone, names and all")
        assertNotNull(stored(Fixture(page = 1), leaving), "memory keeps what it had")
        leaving.end()
        val next = launch()
        assertEquals(null, stored(Fixture(page = 1), next))
        assertEquals(null, stored(TestAssetPricesQuery(), next), "the work queued before the removal went with it")
        next.end()

        val foreign = TemporaryImage()
        try {
            imageDriver().open(foreign.path).use { connection ->
                connection.prepare("CREATE TABLE notes(text)").use { it.step() }
            }
            val opened = Persistence(foreign.path)
            opened.flush()
            opened.removeAll()
            opened.close()
            assertEquals(0L, integer("SELECT count(*) FROM notes", foreign.path), "the table is still there")
        } finally {
            foreign.delete()
        }
    }
}
