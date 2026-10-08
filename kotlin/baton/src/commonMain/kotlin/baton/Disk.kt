package baton

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteException
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.execSQL
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeMark
import kotlin.time.TimeSource

/**
 * The connection to the image, its prepared statements and the names it
 * interns. Not thread-safe: `Persistence` holds it behind its lock, and
 * whoever holds the lock, the writer or the store's thread, uses it.
 *
 * The file has six tables. `records` holds a row per record: flags
 * (deleted, entity), the type, then cells of storage key, tagged value and
 * optional field error. `root` holds the query root a row per field, because
 * the root is a directory of entry points rather than an entity. `fetches`
 * holds when each operation last committed a response. `names` interns type
 * names and storage keys, because slot indices belong to a process and names
 * do not. `memberships` keeps what responses said of types the build did not
 * list, and `meta` the version and the generation. Every row carries the
 * generation, a launch counter, of its last write or read.
 */
@OptIn(ExperimentalAtomicApi::class)
internal class Disk(private val path: String, private val version: String, private val sizeLimit: Int) {
    /** What an open found. */
    sealed interface Opening {
        data object Already : Opening

        /** Just opened: the fetch times the file holds, by operation, and the memberships responses taught, by type and condition name. */
        class Opened(val times: Map<String, Double>, val memberships: List<Pair<String, String>>) : Opening

        data object Unavailable : Opening
    }

    private enum class Kind {
        /** Not an image this build can read: delete it and start again. */
        UNREADABLE,

        /** A database of another kind: leave it, and leave it for good. */
        FOREIGN,

        /** Anything else, a locked file included: leave it and try later. */
        UNAVAILABLE,
    }

    private class Failure(val kind: Kind) : Exception()

    private var db: SQLiteConnection? = null
    private var retryAfter: TimeMark? = null

    /**
     * Set when the file is another program's database, or when another
     * image in the process holds it: this image stays off for the process,
     * leaves the file alone, and does not ask again every second.
     */
    var off = false
        private set

    /** Whether this image holds its file among the process's images: from its creation until its `release()`. */
    var holding = false
        private set

    /**
     * Whether the image has given its file back for good. The next image on
     * the file is the store that comes after; a read or a write that reaches
     * a closed image, from a store that is ending, must not take the file
     * from it, so a closed image never opens again.
     */
    var closed = false
        private set

    /** Whether this image has moved the generation already: a connection opened again after a failure is the same launch. */
    private var launched = false

    /** Whether rows no launch has touched since the one before last have been deleted, which the writer's first batch does. */
    private var aged = false

    /** Set when SQLite reports the file corrupt; it is discarded at the end of the read or write that found out. */
    private var damaged = false

    var generation = 0L
        private set

    /** The prepared statements of the open connection, closed with it. */
    private class Prepared(
        val selectRecord: SQLiteStatement,
        val upsertRecord: SQLiteStatement,
        val useRecord: SQLiteStatement,
        val selectRoot: SQLiteStatement,
        val upsertRoot: SQLiteStatement,
        val useRoot: SQLiteStatement,
        val upsertFetch: SQLiteStatement,
        val useFetch: SQLiteStatement,
        val upsertName: SQLiteStatement,
        val deleteName: SQLiteStatement,
        val upsertMembership: SQLiteStatement,
        val forgetRecord: SQLiteStatement,
        val forgetID: SQLiteStatement,
        val begin: SQLiteStatement,
        val beginReading: SQLiteStatement,
        val commit: SQLiteStatement,
        val rollback: SQLiteStatement,
    ) {
        val all: List<SQLiteStatement>
            get() = listOf(
                selectRecord, upsertRecord, useRecord, selectRoot, upsertRoot, useRoot, upsertFetch, useFetch,
                upsertName, deleteName, upsertMembership, forgetRecord, forgetID, begin, beginReading, commit, rollback,
            )
    }

    private var prepared: Prepared? = null

    /** Names by id, and back; null at an id a sweep freed. */
    private val names = ArrayList<String?>()
    private val ids = HashMap<String, Int>()
    /** The ids a sweep freed, to use again, the lowest last. */
    private val freeNames = ArrayList<Int>()
    /** Names interned since the last transaction that committed. */
    private val unwritten = ArrayList<Int>()
    /** By slot: the name id of its storage key, or -2 for a slot that is never written. */
    private val slotNames = HashMap<Slot, Int>()
    /** By type: the name id of the type's name. */
    private val typeNames = HashMap<Int, Int>()
    /** By type and name id: the slot index the name is on the type. */
    private val slots = HashMap<Long, Int>()
    /** By name id: the type of that name. */
    private val types = HashMap<Int, TypeID>()

    private val writer = RowWriter()
    private val readRecords = ArrayList<String>()
    private val readRoot = ArrayList<String>()

    init {
        claim()
    }

    /** Takes the file for this image unless another image holds it, in which case this one stays off. */
    private fun claim(): Boolean {
        while (true) {
            val current = held.load()
            if (path in current) {
                holding = false
                off = true
                return false
            }
            if (held.compareAndSet(current, current + path)) {
                holding = true
                return true
            }
        }
    }

    /** Gives the file back, for another image to take. */
    private fun letGo() {
        if (!holding) return
        holding = false
        while (true) {
            val current = held.load()
            if (held.compareAndSet(current, current - path)) return
        }
    }

    // Opening.

    /**
     * Opens the file unless it is open. An unreadable file is deleted and
     * started again; any other failure, a locked file among them, leaves the
     * image off for a second, and the work queued meanwhile waits.
     */
    fun open(): Opening {
        if (db != null) return Opening.Already
        if (off || closed || !holding) return Opening.Unavailable
        retryAfter?.let { if (!it.hasPassedNow()) return Opening.Unavailable }
        // An image marked to be discarded, for work it dropped or a removal
        // a crash interrupted, is deleted before anything is read. A file of
        // another kind under the marker is left, and the marker goes.
        if (imageFileExists(marker)) {
            when (inspect()) {
                File.IMAGE -> discard()
                File.ABSENT, File.FOREIGN -> Unit
                File.UNAVAILABLE -> {
                    retryAfter = TimeSource.Monotonic.markNow() + 1.seconds
                    return Opening.Unavailable
                }
            }
            deleteImageFile(marker)
        }
        for (attempt in 0 until 2) {
            try {
                return connect()
            } catch (failure: Failure) {
                if (failure.kind == Kind.UNREADABLE && attempt == 0) {
                    discard()
                    continue
                }
                if (failure.kind == Kind.FOREIGN) off = true
                break
            }
        }
        disconnect()
        retryAfter = TimeSource.Monotonic.markNow() + 1.seconds
        return Opening.Unavailable
    }

    private fun connect(): Opening.Opened {
        makeImageDirectory(path)
        db = guarded { imageDriver().open(path) }
        // One process uses an image; the wait only covers a connection that is still closing.
        integer("PRAGMA busy_timeout = 250")

        // Whose file it is comes first: nothing is changed in a database that is not an image.
        val application = integer("PRAGMA application_id")
        val format = integer("PRAGMA user_version")
        // Android's framework adds a table of its own, `android_metadata`, to
        // every database it opens, so a new file there already holds one.
        val tables = integer("SELECT count(*) FROM sqlite_master WHERE name != 'android_metadata'")
        val fresh = application == 0L && format == 0L && tables == 0L
        if (!fresh && application != APPLICATION_ID) throw Failure(Kind.FOREIGN)
        if (!fresh && format != FORMAT) throw Failure(Kind.UNREADABLE)
        // Cache-grade durability: a commit does not wait for the disk. A
        // crash loses the last moments; the file stays consistent. The mode
        // is set in one step: the statement answers with a row, and Android's
        // driver fails a step past it.
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        // An image that outgrew its limit evicts before it starts over: the
        // rows no launch has used since the one before last go first, as the
        // writer's first batch would drop them, then the previous launch's,
        // and the file shrinks. Only a file still over the limit with nothing
        // left to evict starts again. Recency is the launch's: the rows
        // record the generation that last used them and nothing finer.
        if (!fresh && size() > sizeLimit) {
            val previous = integer("SELECT coalesce((SELECT value FROM meta WHERE key = 'generation'), 0)")
            evict(previous)
            if (size() > sizeLimit) evict(previous + 1)
            if (size() > sizeLimit) throw Failure(Kind.UNREADABLE)
        }
        if (fresh) {
            exec("BEGIN IMMEDIATE")
            exec("PRAGMA application_id=$APPLICATION_ID")
            exec("PRAGMA user_version=$FORMAT")
            exec("CREATE TABLE records(key TEXT PRIMARY KEY NOT NULL, used INTEGER NOT NULL, row BLOB NOT NULL) WITHOUT ROWID")
            exec("CREATE TABLE root(field TEXT PRIMARY KEY NOT NULL, used INTEGER NOT NULL, cell BLOB NOT NULL) WITHOUT ROWID")
            exec("CREATE TABLE fetches(operation TEXT PRIMARY KEY NOT NULL, used INTEGER NOT NULL, time REAL NOT NULL) WITHOUT ROWID")
            exec("CREATE TABLE names(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
            exec("CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value) WITHOUT ROWID")
            exec("CREATE TABLE memberships(type TEXT NOT NULL, condition TEXT NOT NULL, PRIMARY KEY(type, condition)) WITHOUT ROWID")
            exec("COMMIT")
        }

        // A new launch: the app's version decides whether the rows survive,
        // and the generation moves once per image. Rows no launch has
        // touched since the one before last go in the writer's first batch.
        exec("BEGIN IMMEDIATE")
        if (text("SELECT value FROM meta WHERE key = 'version'") != version) {
            for (table in listOf("records", "root", "fetches", "names")) exec("DELETE FROM $table")
            bind("INSERT OR REPLACE INTO meta(key, value) VALUES('version', ?1)") { it.bindText(1, version) }
        }
        val stored = integer("SELECT coalesce((SELECT value FROM meta WHERE key = 'generation'), 0)")
        generation = if (launched) stored else stored + 1
        launched = true
        exec("INSERT OR REPLACE INTO meta(key, value) VALUES('generation', $generation)")
        exec("COMMIT")

        names.clear()
        ids.clear()
        freeNames.clear()
        var readable = true
        each("SELECT id, name FROM names ORDER BY id") { statement ->
            val id = statement.getLong(0)
            if (id < names.size || id - names.size > WIDEST_HOLE || statement.isNull(1)) {
                readable = false
                return@each
            }
            while (names.size < id) names.add(null)
            val name = statement.getText(1)
            ids[name] = id.toInt()
            names.add(name)
        }
        if (!readable) throw Failure(Kind.UNREADABLE)
        for (index in names.indices.reversed()) if (names[index] == null) freeNames.add(index)
        val memberships = ArrayList<Pair<String, String>>()
        each("SELECT type, condition FROM memberships") { statement ->
            memberships.add(statement.getText(0) to statement.getText(1))
        }
        val times = HashMap<String, Double>()
        each("SELECT operation, time FROM fetches WHERE used >= ${generation - 1}") { statement ->
            times[statement.getText(0)] = statement.getDouble(1)
        }

        prepared = Prepared(
            selectRecord = prepare("SELECT used, row FROM records WHERE key = ?1"),
            upsertRecord = prepare("INSERT OR REPLACE INTO records(key, used, row) VALUES(?1, ?2, ?3)"),
            useRecord = prepare("UPDATE records SET used = ?2 WHERE key = ?1"),
            selectRoot = prepare("SELECT used, cell FROM root WHERE field = ?1"),
            upsertRoot = prepare("INSERT OR REPLACE INTO root(field, used, cell) VALUES(?1, ?2, ?3)"),
            useRoot = prepare("UPDATE root SET used = ?2 WHERE field = ?1"),
            upsertFetch = prepare("INSERT OR REPLACE INTO fetches(operation, used, time) VALUES(?1, ?2, ?3)"),
            useFetch = prepare("UPDATE fetches SET used = ?2 WHERE operation = ?1"),
            // A plain insert: an id another connection took fails the batch
            // rather than renaming what every row written with it means.
            upsertName = prepare("INSERT INTO names(id, name) VALUES(?1, ?2)"),
            deleteName = prepare("DELETE FROM names WHERE id = ?1"),
            upsertMembership = prepare("INSERT OR IGNORE INTO memberships(type, condition) VALUES(?1, ?2)"),
            forgetRecord = prepare("DELETE FROM records WHERE key = ?1"),
            forgetID = prepare("DELETE FROM records WHERE key IN (SELECT name || ':' || ?1 FROM names)"),
            begin = prepare("BEGIN IMMEDIATE"),
            beginReading = prepare("BEGIN"),
            commit = prepare("COMMIT"),
            rollback = prepare("ROLLBACK"),
        )
        return Opening.Opened(times, memberships)
    }

    /**
     * Closes the connection and gives the file back for good, so the next
     * image may take it. Work that comes later is dropped and a read misses;
     * a removal still deletes the file.
     */
    fun release() {
        disconnect()
        letGo()
        closed = true
    }

    private fun disconnect() {
        prepared?.all?.forEach { statement -> runCatching { statement.close() } }
        prepared = null
        db?.let { connection -> runCatching { connection.close() } }
        db = null
        damaged = false
        names.clear()
        ids.clear()
        freeNames.clear()
        unwritten.clear()
        slotNames.clear()
        typeNames.clear()
        slots.clear()
        types.clear()
    }

    /**
     * The file whose presence says the image is to be discarded before it is
     * read again: it dropped work memory kept, or its removal was
     * interrupted.
     */
    private val marker: String get() = "$path-discard"

    /** Marks the image to be discarded at the next open. */
    fun mark() {
        if (off) return
        touchImageFile(marker)
    }

    /**
     * Deletes the file for a sign-out when it is an image, under a marker
     * that has the next open finish a delete a crash interrupts, and leaves
     * a database of another kind, or a file another image holds, alone. A
     * file that cannot be opened now is marked for the next open to tell and
     * delete.
     */
    fun erase() {
        if (off) return
        // A released image holds its file for the removal alone, so the next image may still take it.
        val borrowed = !holding
        if (borrowed && !claim()) return
        try {
            // A file the connection does not hold open is told by its application id first: it may never have been opened.
            if (db == null) {
                when (inspect()) {
                    File.IMAGE -> Unit
                    File.ABSENT, File.FOREIGN -> {
                        deleteImageFile(marker)
                        return
                    }
                    File.UNAVAILABLE -> {
                        mark()
                        return
                    }
                }
            }
            mark()
            discard()
            deleteImageFile(marker)
        } finally {
            if (borrowed) letGo()
        }
    }

    private enum class File {
        ABSENT,

        /** An image by its application id, or a file SQLite cannot read as a database at all, which an open deletes and starts again. */
        IMAGE,

        /** A database of another kind. */
        FOREIGN,

        /** A file that cannot be opened now. */
        UNAVAILABLE,
    }

    /** What the path holds, told by a connection of its own. */
    private fun inspect(): File {
        if (!imageFileExists(path)) return File.ABSENT
        val connection = try {
            imageDriver().open(path)
        } catch (_: SQLiteException) {
            return File.UNAVAILABLE
        }
        try {
            return connection.prepare("PRAGMA application_id").use { statement ->
                if (statement.step() && statement.getLong(0) == APPLICATION_ID) File.IMAGE else File.FOREIGN
            }
        } catch (error: SQLiteException) {
            return if (kind(error) == Kind.UNREADABLE) File.IMAGE else File.UNAVAILABLE
        } finally {
            runCatching { connection.close() }
        }
    }

    /** Deletes the rows last used before [generation] and gives their space back, so the size the limit is checked against is the rows that remain. */
    private fun evict(generation: Long) {
        for (table in listOf("records", "root", "fetches")) exec("DELETE FROM $table WHERE used < $generation")
        exec("VACUUM")
        integer("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /** The database's size: its pages, which is the file once its log is folded in. */
    private fun size(): Long = integer("PRAGMA page_count") * integer("PRAGMA page_size")

    /**
     * Deletes the file and its log: an image that cannot be read is a miss,
     * never a migration. The log goes first: a database file left alone is a
     * consistent older image, where a log left alone would be replayed into
     * the next file made at the path.
     */
    private fun discard() {
        disconnect()
        for (suffix in listOf("-wal", "-shm", "")) deleteImageFile(path + suffix)
    }

    /** Whether an error is a file this build cannot read, by the primary result code SQLite reported. */
    private fun kind(error: SQLiteException): Kind {
        // The driver API carries the code in its message alone: "Error code: 26, message: ...".
        val code = error.message?.let { CODE.find(it) }?.groupValues?.get(1)?.toIntOrNull() ?: return Kind.UNAVAILABLE
        val primary = code and 0xff
        return if (primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB) Kind.UNREADABLE else Kind.UNAVAILABLE
    }

    private inline fun <T> guarded(body: () -> T): T = try {
        body()
    } catch (error: SQLiteException) {
        throw Failure(kind(error))
    }

    private fun connection(): SQLiteConnection = db ?: throw Failure(Kind.UNAVAILABLE)

    private fun exec(sql: String) = guarded { connection().execSQL(sql) }

    private fun prepare(sql: String): SQLiteStatement = guarded { connection().prepare(sql) }

    /** Runs a statement once and calls [row] for each row it returns. */
    private fun each(sql: String, row: (SQLiteStatement) -> Unit) = guarded {
        connection().prepare(sql).use { statement -> while (statement.step()) row(statement) }
    }

    private fun integer(sql: String): Long {
        var result = 0L
        each(sql) { result = it.getLong(0) }
        return result
    }

    private fun text(sql: String): String? {
        var result: String? = null
        each(sql) { result = if (it.isNull(0)) null else it.getText(0) }
        return result
    }

    private fun bind(sql: String, bindings: (SQLiteStatement) -> Unit) = guarded {
        connection().prepare(sql).use { statement ->
            bindings(statement)
            statement.step()
        }
    }

    /** Steps a prepared statement that returns no rows; false when SQLite failed it. */
    private fun run(statement: SQLiteStatement): Boolean {
        try {
            statement.step()
            return true
        } catch (error: SQLiteException) {
            if (kind(error) == Kind.UNREADABLE) damaged = true
            return false
        } finally {
            reset(statement)
        }
    }

    /** Resets a statement, which repeats the error a failed step met: that error was handled where it was met. */
    private fun reset(statement: SQLiteStatement) {
        try {
            statement.reset()
            statement.clearBindings()
        } catch (_: SQLiteException) {
        }
    }

    // Reading.

    /** Opens the read transaction a hydration runs in. */
    fun beginRead(): Boolean {
        val prepared = prepared ?: return false
        return run(prepared.beginReading)
    }

    /** Closes the read transaction. Returns the rows the read found carrying an older generation, for the writer to stamp. */
    fun endRead(): Persistence.Work? {
        prepared?.let { run(it.commit) }
        try {
            if (readRecords.isEmpty() && readRoot.isEmpty()) return null
            return Persistence.Work.Used(readRecords.toList(), readRoot.toList())
        } finally {
            readRecords.clear()
            readRoot.clear()
            if (damaged) discard()
        }
    }

    /** Calls [body] with the record's row, if the image has one. */
    fun record(key: String, body: (ByteArray) -> Unit): Boolean {
        val prepared = prepared ?: return false
        return read(prepared.selectRecord, key, Noting.RECORD, body)
    }

    /** Calls [body] with a root field's cell, if the image has one. */
    fun rootField(storageKey: String, body: (ByteArray) -> Unit): Boolean {
        val prepared = prepared ?: return false
        return read(prepared.selectRoot, storageKey, Noting.ROOT, body)
    }

    /** Where a read notes a row it found carrying an older generation, for the writer to stamp: the writer's own read of a row it rewrites at once notes it nowhere. */
    private enum class Noting { RECORD, ROOT, NOWHERE }

    private fun read(statement: SQLiteStatement, key: String, noting: Noting, body: (ByteArray) -> Unit): Boolean {
        val used: Long
        val bytes: ByteArray
        try {
            statement.bindText(1, key)
            if (!statement.step()) return false
            used = statement.getLong(0)
            bytes = statement.getBlob(1)
        } catch (error: SQLiteException) {
            if (kind(error) == Kind.UNREADABLE) damaged = true
            return false
        } finally {
            reset(statement)
        }
        // A row no launch has touched since the one before last is gone, though the writer's first batch has not deleted it yet.
        if (used < generation - 1) return false
        if (used != generation) {
            when (noting) {
                Noting.RECORD -> readRecords.add(key)
                Noting.ROOT -> readRoot.add(key)
                Noting.NOWHERE -> Unit
            }
        }
        body(bytes)
        return true
    }

    /**
     * The slot a stored name is on a type, interning it for this store. A
     * name with arguments is the store's to number, as a rendering, unless
     * the build names it as a constant: the file cannot tell the two apart.
     * One without arguments is the build's.
     */
    fun slot(name: Int, type: TypeID, keys: Keys): Slot? {
        if (name < 0 || name >= names.size) return null
        val cacheKey = (type.raw.toLong() shl 32) or name.toLong()
        slots[cacheKey]?.let { return Slot(type, it) }
        val storageKey = names[name] ?: return null
        val slot = if ('(' in storageKey) keys.slot(type, storageKey) else Registry.slot(type, storageKey)
        slots[cacheKey] = slot.index
        return slot
    }

    /** The type a stored name is. */
    fun type(name: Int): TypeID? {
        if (name < 0 || name >= names.size) return null
        types[name]?.let { return it }
        val text = names[name] ?: return null
        val type = Registry.type(text)
        types[name] = type
        return type
    }

    // Writing.

    /**
     * Writes everything in one transaction, and says whether the file took
     * it. A failure rolls the transaction back. A file too damaged to write
     * is discarded and the work lost with it, which a cache can afford;
     * after any other failure, a locked file or a full disk, the connection
     * closes and the work waits to be written at the next drain.
     */
    fun write(work: List<Persistence.Work>): Boolean {
        if (work.isEmpty()) return true
        val prepared = prepared ?: return false
        if (!run(prepared.begin)) return failed()
        var good = true
        if (!aged) {
            good = try {
                for (table in listOf("records", "root", "fetches")) exec("DELETE FROM $table WHERE used < ${generation - 1}")
                true
            } catch (_: Failure) {
                false
            }
            if (good) good = sweepNames(prepared)
            aged = good
        }
        for (item in work) {
            when (item) {
                is Persistence.Work.Commit -> {
                    for (snapshot in item.records) good = put(snapshot, prepared, item.keys) && good
                    for (field in item.root) good = put(field, prepared, item.keys) && good
                }
                is Persistence.Work.Fetched -> good = put(item.operation, item.time, prepared) && good
                is Persistence.Work.Used -> {
                    for (key in item.records) good = use(prepared.useRecord, key) && good
                    for (field in item.root) good = use(prepared.useRoot, field) && good
                }
                is Persistence.Work.Dated -> good = use(prepared.useFetch, item.operation) && good
                is Persistence.Work.Forget -> {
                    for (key in item.keys) good = forget(prepared.forgetRecord, key) && good
                    for (id in item.ids) good = forget(prepared.forgetID, id) && good
                }
                Persistence.Work.Invalidate -> good = (try {
                    exec("DELETE FROM fetches")
                    true
                } catch (_: Failure) {
                    false
                }) && good
                is Persistence.Work.Freed -> forget(item.slots)
                is Persistence.Work.Memberships -> for (membership in item.memberships) good = put(membership, prepared) && good
            }
        }
        for (id in unwritten) good = putName(id, prepared) && good
        if (!good || !run(prepared.commit)) {
            run(prepared.rollback)
            return failed()
        }
        unwritten.clear()
        if (damaged) discard()
        return true
    }

    /** After a transaction failed: a damaged file is discarded now and its work is done with; any other closes, to be opened again, and its work waits. */
    private fun failed(): Boolean {
        if (damaged) {
            discard()
            return true
        }
        disconnect()
        return false
    }

    private fun put(snapshot: RecordSnapshot, prepared: Prepared, keys: Keys): Boolean {
        val record = snapshot.record
        // What hangs off the mutation and subscription roots by path is a
        // payload, read once by its caller; entities inside it have keys of
        // their own and are written as themselves.
        if (record.key.startsWith(MUTATION_PAYLOADS) || record.key.startsWith(SUBSCRIPTION_PAYLOADS)) return true
        // A transient type's records never reach the image; memory keeps them.
        if (Registry.isTransient(record.type)) return true
        writer.reset()
        writer.row(snapshot, ::name, { slot -> name(slot, keys) })
        // A record memory has read from the image holds everything the image
        // does, and its snapshot replaces the row. One it has not read holds
        // what this launch's responses wrote: its row keeps the cells the
        // snapshot does not write. A deleted record replaces its row whatever
        // was read.
        if (!snapshot.hydrated && !snapshot.deleted) read(prepared.selectRecord, record.key, Noting.NOWHERE) { old -> writer.merge(old) }
        return upsert(prepared.upsertRecord, record.key)
    }

    private fun put(field: RootField, prepared: Prepared, keys: Keys): Boolean {
        if (field.value == Value.Missing) return true
        val storageKey = keys.text(field.slot)
        // A transient root field's cell, and so the storage key that would name it with its arguments, never reaches the image.
        if (Registry.isTransientField(field.slot.type, storageKey)) return true
        if (field.value.linksTransient) return true
        writer.reset()
        writer.cell(field, ::name)
        return upsert(prepared.upsertRoot, storageKey)
    }

    /** Binds the key, the generation and the row's bytes, and steps. */
    private fun upsert(statement: SQLiteStatement, key: String): Boolean {
        try {
            statement.bindText(1, key)
            statement.bindLong(2, generation)
            statement.bindBlob(3, writer.bytes())
        } catch (_: SQLiteException) {
            reset(statement)
            return false
        }
        return run(statement)
    }

    private fun put(operation: String, time: Double, prepared: Prepared): Boolean {
        val statement = prepared.upsertFetch
        statement.bindText(1, operation)
        statement.bindLong(2, generation)
        statement.bindDouble(3, time)
        return run(statement)
    }

    private fun put(membership: Pair<String, String>, prepared: Prepared): Boolean {
        val statement = prepared.upsertMembership
        statement.bindText(1, membership.first)
        statement.bindText(2, membership.second)
        return run(statement)
    }

    private fun putName(id: Int, prepared: Prepared): Boolean {
        val name = names.getOrNull(id) ?: return true
        val statement = prepared.upsertName
        statement.bindLong(1, id.toLong())
        statement.bindText(2, name)
        return run(statement)
    }

    /**
     * Deletes the names no row uses any more, once a launch's aging has run,
     * so that the ids and cursors a session rendered leave the file with the
     * rows that carried them and their ids are used again: the table is
     * bounded by the rows. A row that does not read keeps what it names.
     */
    private fun sweepNames(prepared: Prepared): Boolean {
        val used = BooleanArray(names.size)
        for (id in unwritten) used[id] = true
        try {
            each("SELECT row FROM records") { statement -> RowReader(statement.getBlob(0)).namesOfRow(used) }
            each("SELECT cell FROM root") { statement -> RowReader(statement.getBlob(0)).namesOfCell(used) }
        } catch (_: Failure) {
            return false
        }
        var good = true
        for (id in names.indices) {
            if (used[id]) continue
            val name = names[id] ?: continue
            prepared.deleteName.bindLong(1, id.toLong())
            good = run(prepared.deleteName) && good
            ids.remove(name)
            names[id] = null
        }
        // The table ends at its highest name in use; the holes below it are
        // used again, lowest first. What the caches knew by id may now name
        // nothing, and is learned again.
        while (names.isNotEmpty() && names.last() == null) names.removeAt(names.lastIndex)
        freeNames.clear()
        for (index in names.indices.reversed()) if (names[index] == null) freeNames.add(index)
        slotNames.clear()
        typeNames.clear()
        slots.clear()
        types.clear()
        return good
    }

    private fun forget(statement: SQLiteStatement, key: String): Boolean {
        statement.bindText(1, key)
        return run(statement)
    }

    private fun use(statement: SQLiteStatement, key: String): Boolean {
        statement.bindText(1, key)
        statement.bindLong(2, generation)
        return run(statement)
    }

    // Names.

    private fun intern(name: String): Int {
        ids[name]?.let { return it }
        val id: Int
        if (freeNames.isNotEmpty()) {
            id = freeNames.removeAt(freeNames.lastIndex)
            names[id] = name
            // What the caches knew of the id named another text.
            slots.keys.removeAll { (it and 0xffffffffL).toInt() == id }
            types.remove(id)
        } else {
            id = names.size
            names.add(name)
        }
        ids[name] = id
        unwritten.add(id)
        return id
    }

    private fun name(type: TypeID): Int = typeNames.getOrPut(type.raw) { intern(Registry.typeName(type)) }

    /**
     * Forgets what it knew of slots the store freed, whose numbers it will
     * give other texts: the next row written under one interns the new text,
     * and a stored name whose slot was one is looked up again.
     */
    fun forget(freed: List<Slot>) {
        for (slot in freed) {
            if (slot.index >= 0) continue
            slotNames.remove(slot)
            slots.entries.removeAll { (key, index) -> (key ushr 32).toInt() == slot.type.raw && index == slot.index }
        }
    }

    /** The name id of a slot's storage key, which the store's keys give for a slot the store numbered; negative for a slot that is never written. */
    private fun name(slot: Slot, keys: Keys): Int = slotNames.getOrPut(slot) {
        val storageKey = keys.text(slot)
        if (storageKey in REQUEST_STATE) -2 else intern(storageKey)
    }

    companion object {
        /**
         * The row format. A file of another format is discarded. The rows
         * are laid out as the Swift runtime's sixth format, which this
         * number names.
         */
        const val FORMAT = 6L

        /** Marks the file as an image, so a database of another kind is left alone. */
        const val APPLICATION_ID = 0x4241544EL

        /** A hole in the table of names wider than this is a damaged file, not one to size the table by. */
        const val WIDEST_HOLE = 1 shl 20

        /** Client fields that describe a request in flight, not data. */
        val REQUEST_STATE = setOf("__isLoadingNext", "__isLoadingPrevious")

        /** The key prefixes of records that hang off the mutation and the subscription root by path. */
        const val MUTATION_PAYLOADS = Store.MUTATION_ROOT_KEY + ":"
        const val SUBSCRIPTION_PAYLOADS = Store.SUBSCRIPTION_ROOT_KEY + ":"

        private const val SQLITE_CORRUPT = 11
        private const val SQLITE_NOTADB = 26
        private val CODE = Regex("Error code: (\\d+)")

        /** The files the process's images hold, by path: one image writes a file at a time. */
        private val held = AtomicReference<Set<String>>(emptySet())
    }
}
