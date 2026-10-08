package baton

import kotlin.math.max
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The store's image on disk: the records the server has told the store
 * about, written behind every commit and read back when the store is asked
 * for data it does not hold. One SQLite file through the AndroidX SQLite
 * driver the platform supplies. See `spec/runtime.md`, section 9.
 *
 * Memory stays the truth: a read from the image fills only what memory
 * lacks. The image is a cache: a file of another format or version and a
 * corrupt file are deleted and started again; a file over its size limit
 * evicts the rows of launches before the last, then the last launch's, and
 * starts again only when nothing is left to evict; and a record that goes a
 * whole launch unread is dropped at the next. An image is made for one store
 * and lives as long as it: the environment's end closes it and gives the
 * file back, and the next environment makes its own, on that file or
 * another. One process uses a file through one image at a time: a second
 * image made on a file another holds runs without it. A file that cannot be
 * opened for a while keeps the writer's work until it can.
 *
 * The writer runs on a thread of its own; the events it logs, `imageOpened`,
 * `imageUnavailable`, `imageWritten` and `imageWriteFailed`, arrive there.
 */
class Persistence(
    /** The file's path; its directory is made when missing. */
    val path: String,
    /**
     * The app's own version of what it caches. An image written under
     * another version is discarded: change it on a release whose schema
     * gives a field another type.
     */
    val version: String = "",
    /** The file size, in bytes, past which the image evicts at launch. */
    val sizeLimit: Int = 64 shl 20,
) {
    /** One thing the store's thread asked the writer to do, in order. */
    internal sealed interface Work {
        /** Changed records and root fields, with the store's keys, which name the slots a row is written under. */
        class Commit(val records: List<RecordSnapshot>, val root: List<RootField>, val keys: Keys) : Work

        /** What a response said of types the build did not list, by the type's and the condition's names, for the next launch. */
        class Memberships(val memberships: List<Pair<String, String>>) : Work

        class Fetched(val operation: String, val time: Double) : Work

        /** Rows a read found carrying an older generation. */
        class Used(val records: List<String>, val root: List<String>) : Work

        /** A fetch time this launch read, which keeps it for the next. */
        class Dated(val operation: String) : Work

        /** Records a server's payload changed in a way memory could not apply, by key, and by bare id under every type the image names. */
        class Forget(val keys: List<String>, val ids: List<String>) : Work

        data object Invalidate : Work

        /** Slots the store freed, whose numbers it gives other texts: the image forgets the names it had for them. */
        class Freed(val slots: List<Slot>) : Work
    }

    private class Pending {
        val work = ArrayList<Work>()
        /** The work the writer has taken and not yet written. */
        var writing: List<Work> = emptyList()
        var scheduled = false
        /** How many forgets wait to be written: queued, or taken and not yet in the file. */
        var forgets = 0
        /** Whether the writer is held: the work waits in the queue until it is let go. For the tests. */
        var held = false
    }

    /** When each operation last committed a response, by the wall clock. */
    private class Ages {
        val times = HashMap<String, Double>()
        /** The operations whose time this launch read and stamped. */
        val read = HashSet<String>()
        /** Set by an invalidation or a removal that ran before the file's own times were loaded, so the load does not bring them back. */
        var cleared = false
    }

    private val disk = Disk(canonicalImagePath(path), version, sizeLimit)
    private val diskLock = imageLock()
    /** Guards the queue, the ages, the memberships and the log, which the store's thread and the writer share. */
    private val stateLock = imageLock()
    private val pending = Pending()
    private val ages = Ages()
    private val memberships = ArrayList<Pair<String, String>>()
    private var logger: ((LogEvent) -> Unit)? = null
    private val dispatcher = imageWriterDispatcher()
    private val writer = CoroutineScope(SupervisorJob() + dispatcher)

    init {
        // The file is opened at once, off the caller's thread.
        writer.launch { drain() }
    }

    /** Waits until everything committed so far is in the file: for tests, and for an app about to be suspended. */
    suspend fun flush() {
        withContext(dispatcher) { drain() }
    }

    /**
     * Writes what is queued, closes the file and gives it back for good, so
     * a new image may take it over: what the environment's end does. Work
     * queued later is dropped and a read that needs the image misses, since
     * the store is ending and the file is the next store's. The new image
     * counts as a launch, though the process is the same.
     */
    suspend fun close() {
        withContext(dispatcher) {
            diskLock.withLock {
                val work = take()
                // Work the file cannot take by the close is lost: the store it was for is ending.
                if (work.isNotEmpty() && opened()) disk.write(work)
                finished(work)
                disk.release()
            }
        }
    }

    /**
     * Deletes the image's file, for a sign-out: the work queued before it is
     * dropped and the file removed, names and argument values with it. A
     * database of another kind at the path is left alone. A marker beside
     * the file has the next open finish a deletion a crash interrupted. The
     * order of a sign-out is the app's: end the environment, which closes
     * the image and commits nothing after, remove the image, forget the
     * credential last.
     */
    fun removeAll() {
        stateLock.withLock {
            ages.times.clear()
            ages.cleared = true
            pending.work.clear()
            pending.forgets = 0
        }
        diskLock.withLock { disk.erase() }
    }

    // From the store's thread.

    /** The environment's log, which the writer calls from its own thread. */
    internal var log: ((LogEvent) -> Unit)?
        get() = stateLock.withLock { logger }
        set(value) = stateLock.withLock { logger = value }

    private fun log(event: LogEvent) {
        stateLock.withLock { logger }?.invoke(event)
    }

    /** Queues what a commit changed. */
    internal fun committed(records: List<RecordSnapshot>, root: List<RootField>, keys: Keys) {
        enqueue(Work.Commit(records, root, keys))
    }

    /** Queues memberships a response taught, for the next launch. */
    internal fun learned(memberships: List<Pair<String, String>>) {
        if (memberships.isNotEmpty()) enqueue(Work.Memberships(memberships))
    }

    /** The memberships the image holds that the store has not taken yet, read when the file opened. */
    internal fun takeMemberships(): List<Pair<String, String>> = stateLock.withLock {
        val taken = memberships.toList()
        memberships.clear()
        taken
    }

    /** Tells the image the slots the store freed. */
    internal fun freed(slots: List<Slot>) {
        enqueue(Work.Freed(slots))
    }

    /** Adds the store's numbers the rows waiting to be written, queued or being written, are named by: the collector frees none of them before the writer has named them. */
    internal fun unwrittenSlots(into: MutableSet<Slot>) {
        stateLock.withLock {
            for (work in pending.work + pending.writing) {
                if (work !is Work.Commit) continue
                for (snapshot in work.records) snapshot.renderedSlots(into)
                for (field in work.root) if (field.slot.index < 0) into.add(field.slot)
            }
        }
    }

    /** Queues the records a payload could not edit in memory, for the image to drop: the next read misses them and fetches. */
    internal fun forget(keys: List<String>, ids: List<String>) {
        enqueue(Work.Forget(keys, ids))
    }

    /** Whether a forget waits to be written, the rows it names still in the file. */
    internal val forgetting: Boolean get() = stateLock.withLock { pending.forgets > 0 }

    /** Notes that an operation's response just committed, at the store's wall time. */
    internal fun fetched(operation: String, time: Double) {
        stateLock.withLock { ages.times[operation] = time }
        enqueue(Work.Fetched(operation, time))
    }

    /**
     * How many seconds ago the operation's last response committed, in this
     * launch or an earlier one. A time read from the image is stamped as
     * used, once per launch, so data read every launch keeps its age.
     */
    internal fun age(operation: String, now: Double): Double? {
        var first = false
        val time = stateLock.withLock {
            first = ages.read.add(operation)
            ages.times[operation]
        } ?: return null
        if (first) enqueue(Work.Dated(operation))
        return max(0.0, now - time)
    }

    /** Forgets every fetch time, so data from the image reads as stale. */
    internal fun invalidate() {
        stateLock.withLock {
            ages.times.clear()
            ages.cleared = true
        }
        enqueue(Work.Invalidate)
    }

    /**
     * Runs [body] holding the connection, inside one read transaction. It
     * writes nothing first: a batch the writer is writing lands before the
     * lock is had, and the records of a batch still queued are kept in
     * memory by the collector, so a read never meets an older row than
     * memory held. False when the file cannot be opened.
     */
    internal fun reading(body: (Disk) -> Boolean): Boolean {
        var used: Work? = null
        val result = diskLock.withLock {
            if (!opened() || !disk.beginRead()) return@withLock false
            val found = body(disk)
            used = disk.endRead()
            found
        }
        used?.let { enqueue(it) }
        return result
    }

    /**
     * Runs [body] with the writer held, so that what [body] commits is queued
     * and not written until it returns: for the tests, which hold the window
     * between a commit and its write open.
     */
    internal fun holdingTheWriter(body: () -> Unit) {
        stateLock.withLock { pending.held = true }
        body()
        val start = stateLock.withLock {
            pending.held = false
            if (pending.work.isEmpty() || pending.scheduled) return@withLock false
            pending.scheduled = true
            true
        }
        if (start) writer.launch { drain() }
    }

    /**
     * The records the queue has yet to write, which the collector keeps until
     * it has: those whose snapshots wait, and those a waiting root field
     * links to. The root drops its links to swept records, and a field
     * dropped before its row is written would be read back from the row
     * before it.
     */
    internal fun unwrittenRecords(): List<Record> = stateLock.withLock {
        val kept = ArrayList<Record>()
        for (work in pending.work) {
            if (work !is Work.Commit) continue
            for (snapshot in work.records) kept.add(snapshot.record)
            for (field in work.root) {
                when (val value = field.value) {
                    is Value.Ref -> kept.add(value.record)
                    is Value.Refs -> for (target in value.records) if (target != null) kept.add(target)
                    else -> Unit
                }
            }
        }
        kept
    }

    // The writer.

    private fun enqueue(work: Work) {
        val start = stateLock.withLock {
            pending.work.add(work)
            if (work is Work.Forget) pending.forgets += 1
            if (pending.scheduled || pending.held) return@withLock false
            pending.scheduled = true
            true
        }
        if (start) writer.launch { drain() }
    }

    private fun take(): List<Work> = stateLock.withLock {
        pending.scheduled = false
        // A held writer leaves the work where it is; letting go drains.
        if (pending.held) return@withLock emptyList()
        val work = pending.work.toList()
        pending.work.clear()
        pending.writing = work
        work
    }

    /** Notes that the work is written, or lost with a file that is done with. */
    private fun finished(work: List<Work>) {
        val forgets = work.count { it is Work.Forget }
        stateLock.withLock {
            pending.writing = emptyList()
            if (forgets > 0) pending.forgets = max(0, pending.forgets - forgets)
        }
    }

    /**
     * Puts work the file could not take back ahead of what was queued since,
     * to wait for the next drain. Work that outgrows [WAIT_LIMIT] is dropped
     * instead and the image marked: memory has moved past the file, which is
     * not to be read again.
     */
    private fun keep(work: List<Work>) {
        val dropped = stateLock.withLock {
            pending.writing = emptyList()
            pending.work.addAll(0, work)
            var rows = 0
            for (item in pending.work) if (item is Work.Commit) rows += item.records.size + item.root.size
            if (rows <= WAIT_LIMIT) return@withLock false
            pending.work.clear()
            pending.forgets = 0
            true
        }
        if (dropped) disk.mark()
    }

    /**
     * Opens the file if needed and writes everything queued, in one
     * transaction. Work the file cannot take now, locked or full, waits for
     * the next drain; an image that runs without a file drops it.
     */
    private fun drain() {
        diskLock.withLock {
            val work = take()
            // Forgetting the names of freed slots needs no file: it is done whether or not the image holds one.
            if (work.isNotEmpty() && work.all { it is Work.Freed }) {
                for (item in work) disk.forget((item as Work.Freed).slots)
                finished(work)
                return@withLock
            }
            // A drain behind `close()` has no file to open.
            if (work.isEmpty() && !disk.holding) return@withLock
            if (!opened()) {
                log(LogEvent.ImageUnavailable)
                if (disk.off || disk.closed) finished(work) else keep(work)
                return@withLock
            }
            if (!disk.write(work)) {
                log(LogEvent.ImageWriteFailed)
                if (disk.off || disk.closed) finished(work) else keep(work)
                return@withLock
            }
            if (work.isNotEmpty()) log(LogEvent.ImageWritten(work.size))
            finished(work)
        }
    }

    /** Opens the file unless it is open; at the open, the file's fetch times and memberships are taken in. Called holding the disk's lock. */
    private fun opened(): Boolean {
        when (val opening = disk.open()) {
            Disk.Opening.Already -> return true
            Disk.Opening.Unavailable -> return false
            is Disk.Opening.Opened -> {
                log(LogEvent.ImageOpened)
                stateLock.withLock {
                    if (!ages.cleared) {
                        for ((operation, time) in opening.times) if (ages.times[operation] == null) ages.times[operation] = time
                    }
                    memberships.addAll(opening.memberships)
                }
                return true
            }
        }
    }

    override fun toString(): String = "Persistence($path)"

    companion object {
        /**
         * How many rows the work waiting for a file may hold before it is
         * dropped: the largest store on the bench, so that what waits never
         * outweighs what a store holds at that scale.
         */
        internal const val WAIT_LIMIT = 50_000

        /**
         * An image named [name] under [directory], or where the platform
         * keeps an app's cached data: on the JVM, the user's cache directory
         * (`~/Library/Caches` on a Mac, `$XDG_CACHE_HOME` or `~/.cache`
         * elsewhere, `%LOCALAPPDATA%` on Windows), in a `Baton` directory. A
         * desktop process has no app identity to keep two apps' images apart
         * by, so two apps that both name theirs `"Main"` pass a directory of
         * their own. On Android the runtime holds no `Context`, so the app
         * passes [directory], its `context.cacheDir.path`; without one the
         * call throws `IllegalArgumentException`.
         */
        fun named(name: String, directory: String? = null, version: String = "", sizeLimit: Int = 64 shl 20): Persistence {
            val base = (directory ?: imageDirectory()).trimEnd('/', '\\')
            return Persistence("$base/Baton/$name.sqlite", version, sizeLimit)
        }
    }
}

/**
 * What the image was told to forget and the writer has not yet dropped,
 * which a read must not meet meanwhile: by key, until a response writes that
 * key, and by bare id, but for the keys with the id that a response has
 * written since (a payload with `Location:1` says nothing of `Character:1`).
 * The store keeps one, on its thread.
 */
internal class Forgotten {
    private val keys = HashSet<String>()
    private val ids = HashSet<String>()
    private val rewritten = HashSet<String>()

    val isEmpty: Boolean get() = keys.isEmpty() && ids.isEmpty()

    /** Notes what a batch told the image to forget. A record with an id that an earlier payload wrote is forgotten with the rest. */
    fun note(forgottenKeys: List<String>, forgottenIDs: List<String>) {
        keys.addAll(forgottenKeys)
        ids.addAll(forgottenIDs)
        if (forgottenIDs.isNotEmpty() && rewritten.isNotEmpty()) {
            rewritten.removeAll { key -> idOfEntity(key) in forgottenIDs }
        }
    }

    /** A record a payload wrote is the store's again, by its exact key. */
    fun wrote(key: String, isEntity: Boolean) {
        keys.remove(key)
        if (isEntity && ids.isNotEmpty() && idOfEntity(key) in ids) rewritten.add(key)
    }

    fun clear() {
        keys.clear()
        ids.clear()
        rewritten.clear()
    }

    /** Whether the record's row is not to be read. */
    fun contains(record: Record): Boolean {
        if (record.key in keys) return true
        val id = record.entityID ?: return false
        return id in ids && record.key !in rewritten
    }

    /** The id an entity's key carries: what follows its type's name. */
    private fun idOfEntity(key: String): String = key.substringAfter(':')
}
