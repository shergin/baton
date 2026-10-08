package baton

import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File

// The JVM has no SQLite of its own: the image runs on the bundled engine,
// a dependency of this target alone.

private val driver: SQLiteDriver by lazy { BundledSQLiteDriver() }

internal actual fun imageDriver(): SQLiteDriver = driver

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
