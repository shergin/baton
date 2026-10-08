package baton

import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.AndroidSQLiteDriver

// Android has a SQLite of its own: the image runs on the system's, through
// the framework's `SQLiteDatabase`, and the app carries no engine.

private val driver: SQLiteDriver by lazy { AndroidSQLiteDriver() }

internal actual fun imageDriver(): SQLiteDriver = driver

/**
 * Where an app keeps cached data on Android is its `Context`'s cache
 * directory, and the runtime holds no `Context`: an image named on Android
 * is placed under the directory the app passes, `context.cacheDir.path`.
 */
internal actual fun imageDirectory(): String = throw IllegalArgumentException(
    "Persistence.named on Android takes the directory to keep the image in, such as context.cacheDir.path",
)
