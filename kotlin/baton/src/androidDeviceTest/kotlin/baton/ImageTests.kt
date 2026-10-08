package baton

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import baton.spec.Fixture
import java.io.File
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.runner.RunWith

/**
 * The image on the system's SQLite, reached through `AndroidSQLiteDriver`:
 * what `PersistenceTests` holds on the JVM's bundled engine, the launches
 * over one file in the app's cache directory.
 */
@RunWith(AndroidJUnit4::class)
class ImageTests {
    private val directory: String = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.path
    private val name = "image-${UUID.randomUUID()}"
    private val path = "$directory/Baton/$name.sqlite"

    @AfterTest
    fun deleteTheImage() {
        for (suffix in listOf("", "-wal", "-shm", "-journal", "-discard")) File(path + suffix).delete()
    }

    /** A transport that is never asked: every handle here reads the store alone. */
    private object Unreached : Transport {
        override fun send(request: Request): Flow<ByteArray> = emptyFlow()
    }

    /** An environment over a new store on the image, as a launch of the app makes one. */
    private fun TestScope.launch(): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(Unreached, null, Store(Persistence.named(name, directory = directory)), dispatcher, dispatcher)
    }

    private fun commitTheFixture(environment: Environment) {
        val store = environment.store
        val response = checkNotNull(javaClass.classLoader?.getResourceAsStream("characters-page-1.json")).use { it.readBytes() }
        store.commit(Ingest.normalize(response, store.resolve(Fixture.plan, Fixture(page = 1).variables), Store.ROOT_KEY))
    }

    private fun stored(environment: Environment): Fixture.Data? =
        (environment.handle(Fixture(page = 1), FetchPolicy.STORE_ONLY).phase as? Phase.Ready)?.data

    @Test
    fun a_second_launch_reads_the_fixture_from_the_system_sqlite_and_agrees_with_the_first() = runTest {
        val first = launch()
        commitTheFixture(first)
        val names = assertNotNull(stored(first)).characters?.results?.map { it.name }
        first.end()

        val second = launch()
        assertEquals(3, second.store.count, "nothing is in memory before a handle asks")
        val data = assertNotNull(stored(second), "the image answers the handle")
        assertEquals(901, second.store.count, "898 entities and three roots, as the first launch held")
        assertEquals(names, data.characters?.results?.map { it.name })
        assertEquals(826, data.characters?.info?.count)
        second.end()
    }

    @Test
    fun a_file_that_is_not_a_database_is_started_again_and_holds_the_next_launch_s_rows() = runTest {
        File(path).apply { parentFile?.mkdirs() }.writeText("not a database, ".repeat(512))
        val first = launch()
        commitTheFixture(first)
        first.end()

        val second = launch()
        assertNotNull(stored(second), "the file was made again and written")
        second.end()
    }

    @Test
    fun an_image_named_without_a_directory_is_refused_on_android() {
        assertFailsWith<IllegalArgumentException> { Persistence.named(name) }
    }
}
