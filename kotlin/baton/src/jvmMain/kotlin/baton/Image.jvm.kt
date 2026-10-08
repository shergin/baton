package baton

import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

// The JVM has no SQLite of its own: the image runs on the bundled engine,
// a dependency of this target alone.

private val driver: SQLiteDriver by lazy { BundledSQLiteDriver() }

internal actual fun imageDriver(): SQLiteDriver = driver

internal actual fun imageFileExists(path: String): Boolean = File(path).exists()

internal actual fun deleteImageFile(path: String) {
    File(path).delete()
}

internal actual fun touchImageFile(path: String) {
    File(path).createNewFile()
}

internal actual fun makeImageDirectory(path: String) {
    File(path).absoluteFile.parentFile?.mkdirs()
}

internal actual fun canonicalImagePath(path: String): String {
    val file = File(path).absoluteFile
    // The nearest directory that exists is resolved, and the rest appended,
    // so that nothing is created here.
    var directory: File? = file.parentFile
    val rest = ArrayList<String>()
    rest.add(file.name)
    while (directory != null && !directory.exists()) {
        rest.add(directory.name)
        directory = directory.parentFile
    }
    val base = directory?.canonicalFile ?: return file.path
    return rest.asReversed().fold(base) { parent, name -> File(parent, name) }.path
}

/**
 * The user's cache directory: `~/Library/Caches` on a Mac,
 * `$XDG_CACHE_HOME` or `~/.cache` elsewhere, `%LOCALAPPDATA%` on Windows.
 * A desktop JVM has no app identity to keep two apps apart by, so the
 * image's name, or a directory the app passes, does.
 */
internal actual fun imageDirectory(): String {
    val home = System.getProperty("user.home")
    val system = System.getProperty("os.name").orEmpty().lowercase()
    return when {
        "mac" in system -> File(home, "Library/Caches").path
        "windows" in system -> System.getenv("LOCALAPPDATA") ?: File(home, "AppData/Local").path
        else -> System.getenv("XDG_CACHE_HOME")?.takeIf { it.isNotEmpty() } ?: File(home, ".cache").path
    }
}

internal actual fun imageWriterDispatcher(): CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1)

internal actual fun imageLock(): ImageLock = object : ImageLock {
    private val lock = ReentrantLock()

    override fun <T> withLock(body: () -> T): T = lock.withLock(body)
}
