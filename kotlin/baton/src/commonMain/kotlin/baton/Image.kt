package baton

import androidx.sqlite.SQLiteDriver
import kotlinx.coroutines.CoroutineDispatcher

// The image's platform piece: the SQLite driver a target supplies, the few
// file operations around the database that SQL cannot make, where the
// platform keeps an app's data, the writer's thread and the lock the store's
// thread and the writer share the connection under. The image itself, its
// schema, rows and rules, is common code over the AndroidX SQLite driver
// API; see `docs/decisions/the-kotlin-runtime-is-common-first.md`.

/** The driver the image opens its file with: the platform's SQLite, or one the target bundles. */
internal expect fun imageDriver(): SQLiteDriver

/** Whether a file exists at [path]. */
internal expect fun imageFileExists(path: String): Boolean

/** Deletes the file at [path], if there is one. */
internal expect fun deleteImageFile(path: String)

/** Makes an empty file at [path], if there is none: the image's marker. */
internal expect fun touchImageFile(path: String)

/** Makes the directory that holds the file at [path], and its parents, when missing. */
internal expect fun makeImageDirectory(path: String)

/**
 * The path with its directory's symbolic links resolved, by which the image
 * claims its file: every spelling of one file names it alike, whether the
 * file exists yet or not.
 */
internal expect fun canonicalImagePath(path: String): String

/** The directory an image named but not placed lives under: where the platform keeps an app's cached data. */
internal expect fun imageDirectory(): String

/** The dispatcher an image's writer runs on: a thread of its own, off the store's. */
internal expect fun imageWriterDispatcher(): CoroutineDispatcher
