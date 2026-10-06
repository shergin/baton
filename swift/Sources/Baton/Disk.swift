import Foundation
import SQLite3
import Synchronization

/// The connection to the image, its prepared statements and the names it
/// interns. Not thread-safe: `Persistence` holds it behind its lock, and
/// whoever holds the lock, the writer's task or the main actor, uses it.
///
/// The file has four tables. `records` holds a row per record: flags
/// (deleted, entity), the type, then cells of storage key, tagged value and
/// optional field error. `root` holds the query root a row per field, because
/// the root is a directory of entry points rather than an entity. `fetches`
/// holds when each operation last committed a response. `names` interns type
/// names and storage keys, because slot indices belong to a process and names
/// do not. Every row carries the generation, a launch counter, of its last
/// write or read.
final class Disk: @unchecked Sendable {
    /// The row format. A file of another format is discarded. 2: a path key
    /// under an interface or union ends in the record's concrete type. 3: a
    /// field error carries its `extensions` as JSON text after its path. 4:
    /// the table of names may have holes, its names swept with the rows that
    /// used them. 5: a storage key leaves a null argument out.
    static let format: Int64 = 5
    /// Marks the file as an image, so a database of another kind is left alone.
    static let applicationID: Int64 = 0x4241_544E
    /// A hole in the table of names wider than this is a damaged file, not
    /// one to size the table by: a sweep leaves holes as wide as the names
    /// it deleted, which the rows of one image bound far below it.
    static let widestHole = 1 << 20
    /// Client fields that describe a request in flight, not data.
    static let requestState: Set<String> = ["__isLoadingNext", "__isLoadingPrevious"]
    /// The files the process's images hold, by path. One image writes a file
    /// at a time: a second would interleave its names and generations with
    /// the first's.
    private static let held = Mutex<Set<String>>([])
    /// The key prefixes of records that hang off the mutation and the
    /// subscription root by path.
    static let mutationPayloads = Store.mutationRootKey + ":"
    static let subscriptionPayloads = Store.subscriptionRootKey + ":"

    enum Opening {
        case already
        /// Just opened: the fetch times the file holds, by operation.
        case opened([String: Double])
        case unavailable
    }

    private enum Failure: Error {
        /// Not an image this build can read: delete it and start again.
        case unreadable
        /// A database of another kind: leave it, and leave it for good.
        case foreign
        /// Anything else, a locked device included: leave it and try later.
        case unavailable
    }

    private let path: String
    private let version: String
    private let sizeLimit: Int
    /// The platform's protection class the file is made with, or nil for
    /// its directory's default. Apple's SQLite takes it as an open flag and
    /// gives the write-ahead log the same class.
    private let protection: FileProtectionType?
    private var db: OpaquePointer?
    private var retryAfter: UInt64 = 0
    /// Set when the file is another program's database, or when another
    /// image in the process holds it: this image stays off for the process,
    /// leaves the file alone, and does not ask again every second.
    private(set) var off = false
    /// Whether this image holds its file among the process's images: from
    /// its creation, or from the open after a `release()`, until the next
    /// `release()` or its end.
    private(set) var holding = false
    /// Whether this image has moved the generation already: a connection
    /// opened again after a failure or a `release()` is the same launch. A
    /// new image on the file moves it again, as a launch does.
    private var launched = false
    /// Whether rows no launch has touched since the one before last have
    /// been deleted, which the writer's first batch does: three scans that
    /// opening the file does not wait for.
    private var aged = false
    /// Set when SQLite reports the file corrupt; it is discarded at the end
    /// of the read or write that found out.
    private var damaged = false
    private(set) var generation: Int64 = 0

    /// The prepared statements of the open connection. They are dropped
    /// with it, so a statement can never be stepped after its connection
    /// closed.
    private struct Prepared {
        let selectRecord, upsertRecord, useRecord: OpaquePointer
        let selectRoot, upsertRoot, useRoot: OpaquePointer
        let upsertFetch, useFetch, upsertName, deleteName: OpaquePointer
        let forgetRecord, forgetID: OpaquePointer
        let begin, beginReading, commit, rollback: OpaquePointer
    }

    /// Every statement prepared on the connection, finalized when it closes.
    private var statements: [OpaquePointer] = []
    private var prepared: Prepared?

    /// Names by id, and back.
    /// Nil at an id a sweep freed.
    private var names: [String?] = []
    private var ids: [String: Int32] = [:]
    /// The ids a sweep freed, to use again, the lowest last.
    private var freeNames: [Int32] = []
    /// Names interned since the last transaction that committed.
    private var unwritten: [Int32] = []
    /// By type, then by the index of a dense slot: the name id, -1 when not
    /// asked yet, -2 for a slot that is never written. The file holds names
    /// only, so which kind a slot is stays this process's own.
    private var slotNames: [[Int32]] = []
    /// The same for the slots numbered apart, by `~index`.
    private var renderedNames: [[Int32]] = []
    /// By type: the name id of the type's name, or -1.
    private var typeNames: [Int32] = []
    /// By type, then by name id: the slot index, or `Int32.min`.
    private var slots: [[Int32]] = []
    /// By name id: the type of that name.
    private var types: [TypeID?] = []

    private var writer = RowWriter()
    private var hydrationHold: Keys.Hold?
    private var readRecords: [String] = []
    private var readRoot: [String] = []

    init(path: String, version: String, sizeLimit: Int, protection: FileProtectionType?) {
        self.path = path
        self.version = version
        self.sizeLimit = sizeLimit
        self.protection = protection
        let claimed = claim()
        assert(claimed, "another Persistence in this process holds \(path); close() it before making another")
    }

    deinit {
        close()
        letGo()
    }

    /// Takes the file for this image unless another image holds it, in
    /// which case this one stays off.
    private func claim() -> Bool {
        holding = Disk.held.withLock { $0.insert(path).inserted }
        if !holding { off = true }
        return holding
    }

    /// Gives the file back, for another image to take.
    private func letGo() {
        guard holding else { return }
        holding = false
        _ = Disk.held.withLock { $0.remove(path) }
    }

    // MARK: Opening

    /// Opens the file unless it is open. An unreadable file is deleted and
    /// started again; any other failure, a locked file among them, leaves
    /// the image off for a second, and the work queued meanwhile waits.
    func open() -> Opening {
        if db != nil { return .already }
        if off { return .unavailable }
        // A released image takes its file again, unless another took it
        // over meanwhile.
        if !holding, !claim() { return .unavailable }
        let now = DispatchTime.now().uptimeNanoseconds
        if now < retryAfter { return .unavailable }
        // An image marked to be discarded, for work it dropped or a removal
        // a crash interrupted, is deleted before anything is read. A file of
        // another kind under the marker is left, and the marker goes.
        if FileManager.default.fileExists(atPath: marker) {
            switch inspect() {
            case .image:
                discard()
            case .absent, .foreign:
                break
            case .unavailable:
                retryAfter = now + 1_000_000_000
                return .unavailable
            }
            unmark()
        }
        for attempt in 0..<2 {
            do {
                return .opened(try connect())
            } catch .unreadable where attempt == 0 {
                discard()
            } catch .foreign {
                off = true
                break
            } catch {
                break
            }
        }
        close()
        retryAfter = now + 1_000_000_000
        return .unavailable
    }

    private func connect() throws(Failure) -> [String: Double] {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if let protection, let flag = Disk.flag(for: protection) { flags |= flag }
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        db = handle
        guard status == SQLITE_OK else { throw failure(status) }
        // One process uses an image; the wait only covers a connection that
        // is still closing.
        sqlite3_busy_timeout(db, 250)

        // Whose file it is comes first: nothing is changed in a database that
        // is not an image.
        let application = try integer("PRAGMA application_id")
        let format = try integer("PRAGMA user_version")
        let tables = try integer("SELECT count(*) FROM sqlite_master")
        let fresh = application == 0 && format == 0 && tables == 0
        if !fresh, application != Disk.applicationID { throw .foreign }
        if !fresh, format != Disk.format { throw .unreadable }
        // The protection is the file's from its creation: a file made under
        // another starts again, so that what the image states is true of it.
        if !fresh, try text("SELECT value FROM meta WHERE key = 'protection'") != protection?.rawValue { throw .unreadable }
        // An image that outgrew its limit starts over.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > sizeLimit {
            throw .unreadable
        }

        // Cache-grade durability: a commit does not wait for the disk, and a
        // checkpoint does not force the drive's own cache. A crash loses the
        // last moments; the file stays consistent.
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA checkpoint_fullfsync=OFF")
        if fresh {
            try exec("""
                BEGIN IMMEDIATE;
                PRAGMA application_id=\(Disk.applicationID);
                PRAGMA user_version=\(Disk.format);
                CREATE TABLE records(key TEXT PRIMARY KEY NOT NULL, used INTEGER NOT NULL, row BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE root(field TEXT PRIMARY KEY NOT NULL, used INTEGER NOT NULL, cell BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE fetches(operation TEXT PRIMARY KEY NOT NULL, used INTEGER NOT NULL, time REAL NOT NULL) WITHOUT ROWID;
                CREATE TABLE names(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value) WITHOUT ROWID;
                COMMIT
                """)
        }

        // A new launch: the app's version decides whether the rows survive,
        // and the generation moves once per image. Rows no launch has
        // touched since the one before last go in the writer's first batch.
        try exec("BEGIN IMMEDIATE")
        if fresh, let protection {
            try bind("INSERT INTO meta(key, value) VALUES('protection', ?1)") { sqlite3_bind_text($0, 1, protection.rawValue, -1, copied) }
        }
        if try text("SELECT value FROM meta WHERE key = 'version'") != version {
            try exec("DELETE FROM records; DELETE FROM root; DELETE FROM fetches; DELETE FROM names")
            try bind("INSERT OR REPLACE INTO meta(key, value) VALUES('version', ?1)") { sqlite3_bind_text($0, 1, version, -1, copied) }
        }
        let stored = try integer("SELECT coalesce((SELECT value FROM meta WHERE key = 'generation'), 0)")
        generation = launched ? stored : stored + 1
        launched = true
        try exec("""
            INSERT OR REPLACE INTO meta(key, value) VALUES('generation', \(generation));
            COMMIT
            """)
        // A class the open takes no flag for is set on the file and its log
        // once they exist.
        if fresh, let protection, Disk.flag(for: protection) == nil {
            for suffix in ["", "-wal"] {
                try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: path + suffix)
            }
        }

        names.removeAll()
        ids.removeAll()
        freeNames.removeAll()
        var readable = true
        try each("SELECT id, name FROM names ORDER BY id") { statement in
            let id = Int(sqlite3_column_int64(statement, 0))
            guard id >= names.count, id - names.count <= Disk.widestHole, let name = sqlite3_column_text(statement, 1) else {
                readable = false
                return
            }
            while names.count < id { names.append(nil) }
            ids[String(cString: name)] = Int32(id)
            names.append(String(cString: name))
        }
        if !readable { throw .unreadable }
        freeNames = names.indices.reversed().compactMap { names[$0] == nil ? Int32($0) : nil }
        var times: [String: Double] = [:]
        try each("SELECT operation, time FROM fetches WHERE used >= \(generation - 1)") { statement in
            guard let operation = sqlite3_column_text(statement, 0) else { return }
            times[String(cString: operation)] = sqlite3_column_double(statement, 1)
        }

        prepared = Prepared(
            selectRecord: try prepare("SELECT used, row FROM records WHERE key = ?1"),
            upsertRecord: try prepare("INSERT OR REPLACE INTO records(key, used, row) VALUES(?1, ?2, ?3)"),
            useRecord: try prepare("UPDATE records SET used = ?2 WHERE key = ?1"),
            selectRoot: try prepare("SELECT used, cell FROM root WHERE field = ?1"),
            upsertRoot: try prepare("INSERT OR REPLACE INTO root(field, used, cell) VALUES(?1, ?2, ?3)"),
            useRoot: try prepare("UPDATE root SET used = ?2 WHERE field = ?1"),
            upsertFetch: try prepare("INSERT OR REPLACE INTO fetches(operation, used, time) VALUES(?1, ?2, ?3)"),
            useFetch: try prepare("UPDATE fetches SET used = ?2 WHERE operation = ?1"),
            // A plain insert: an id another connection took fails the batch
            // rather than renaming what every row written with it means.
            upsertName: try prepare("INSERT INTO names(id, name) VALUES(?1, ?2)"),
            deleteName: try prepare("DELETE FROM names WHERE id = ?1"),
            forgetRecord: try prepare("DELETE FROM records WHERE key = ?1"),
            forgetID: try prepare("DELETE FROM records WHERE key IN (SELECT name || ':' || ?1 FROM names)"),
            begin: try prepare("BEGIN IMMEDIATE"),
            beginReading: try prepare("BEGIN"),
            commit: try prepare("COMMIT"),
            rollback: try prepare("ROLLBACK")
        )
        return times
    }

    /// The open flag under which Apple's SQLite makes the file with the
    /// protection class, and its write-ahead log with it; nil for a class
    /// the library has no flag for.
    private static func flag(for protection: FileProtectionType) -> Int32? {
        switch protection {
        case .complete: SQLITE_OPEN_FILEPROTECTION_COMPLETE
        case .completeUnlessOpen: SQLITE_OPEN_FILEPROTECTION_COMPLETEUNLESSOPEN
        case .completeUntilFirstUserAuthentication: SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        case .none: SQLITE_OPEN_FILEPROTECTION_NONE
        default: nil
        }
    }

    /// Closes the connection and gives the file back, so another image may
    /// take it, as the tests do to run one launch after another. Work that
    /// comes later takes it again, unless another image has.
    func release() {
        close()
        letGo()
    }

    private func close() {
        prepared = nil
        for statement in statements { sqlite3_finalize(statement) }
        statements.removeAll()
        if let db { sqlite3_close_v2(db) }
        db = nil
        damaged = false
        names.removeAll()
        ids.removeAll()
        freeNames.removeAll()
        unwritten.removeAll()
        slotNames.removeAll()
        renderedNames.removeAll()
        typeNames.removeAll()
        slots.removeAll()
        types.removeAll()
    }

    /// The file whose presence says the image is to be discarded before it
    /// is read again: it dropped work memory kept, or its removal was
    /// interrupted. It covers a crash inside the delete and no more; before
    /// the removal, the image's identity keeps one account's rows from the
    /// next.
    private var marker: String { path + "-discard" }

    /// Marks the image to be discarded at the next open.
    func mark() {
        guard !off else { return }
        FileManager.default.createFile(atPath: marker, contents: nil)
    }

    private func unmark() {
        try? FileManager.default.removeItem(atPath: marker)
    }

    /// Deletes the file for a sign-out when it is an image, under a marker
    /// that has the next open finish a delete a crash interrupts, and leaves
    /// a database of another kind, or a file another image holds, alone;
    /// the next work opens a new one. A file that cannot be opened now, on a
    /// locked device, is marked for the next open to tell and delete.
    func erase() {
        if off { return }
        // A released image holds its file for the removal alone, so the
        // next image may still take it.
        let borrowed = !holding
        if borrowed, !claim() { return }
        defer { if borrowed { letGo() } }
        // A file the connection does not hold open is told by its
        // application id first: it may never have been opened.
        if db == nil {
            switch inspect() {
            case .image:
                break
            case .absent, .foreign:
                unmark()
                return
            case .unavailable:
                mark()
                return
            }
        }
        mark()
        discard()
        unmark()
    }

    private enum File {
        case absent
        /// An image by its application id, or a file SQLite cannot read as
        /// a database at all, which an open deletes and starts again.
        case image
        /// A database of another kind.
        case foreign
        /// A file that cannot be opened now: locked, or another's.
        case unavailable
    }

    /// What the path holds, told by a connection of its own.
    private func inspect() -> File {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        var handle: OpaquePointer?
        defer { sqlite3_close_v2(handle) }
        // Read and write, without create: a read-only connection cannot
        // open a WAL file whose shared memory file is gone.
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return .unavailable }
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(handle, "PRAGMA application_id", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        if status == SQLITE_OK { status = sqlite3_step(statement) }
        if status == SQLITE_ROW { return sqlite3_column_int64(statement, 0) == Disk.applicationID ? .image : .foreign }
        return failure(status) == .unreadable ? .image : .unavailable
    }

    /// Deletes the file and its journal: an image that cannot be read is a
    /// miss, never a migration. The log goes first: a database file left
    /// alone is a consistent older image, where a log left alone would be
    /// replayed into the next file made at the path.
    private func discard() {
        close()
        for suffix in ["-wal", "-shm", ""] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func failure(_ status: Int32) -> Failure {
        let primary = status & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB ? .unreadable : .unavailable
    }

    private func exec(_ sql: String) throws(Failure) {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        if status != SQLITE_OK { throw failure(status) }
    }

    private func prepare(_ sql: String) throws(Failure) -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        statements.append(statement)
        return statement
    }

    /// Runs a statement once and calls `row` for each row it returns.
    private func each(_ sql: String, _ row: (OpaquePointer) -> Void) throws(Failure) {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        defer { sqlite3_finalize(statement) }
        status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            row(statement)
            status = sqlite3_step(statement)
        }
        if status != SQLITE_DONE { throw failure(status) }
    }

    private func integer(_ sql: String) throws(Failure) -> Int64 {
        var result: Int64 = 0
        try each(sql) { result = sqlite3_column_int64($0, 0) }
        return result
    }

    private func text(_ sql: String) throws(Failure) -> String? {
        var result: String?
        try each(sql) { result = sqlite3_column_text($0, 0).map { String(cString: $0) } }
        return result
    }

    private func bind(_ sql: String, _ bindings: (OpaquePointer) -> Void) throws(Failure) {
        var statement: OpaquePointer?
        var status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        status = sqlite3_step(statement)
        if status != SQLITE_DONE { throw failure(status) }
    }

    /// Steps a prepared statement that returns no rows.
    private func run(_ statement: OpaquePointer) -> Bool {
        let status = sqlite3_step(statement)
        sqlite3_reset(statement)
        if status == SQLITE_DONE { return true }
        if failure(status) == .unreadable { damaged = true }
        return false
    }

    // MARK: Reading

    /// Opens the read transaction a hydration runs in.
    func beginRead() -> Bool {
        guard let prepared else { return false }
        return run(prepared.beginReading)
    }

    /// Closes the read transaction. Returns the rows the read found carrying
    /// an older generation, for the writer to stamp.
    func endRead() -> Persistence.Work? {
        if let prepared { _ = run(prepared.commit) }
        defer {
            readRecords.removeAll()
            readRoot.removeAll()
            if damaged { discard() }
        }
        if readRecords.isEmpty, readRoot.isEmpty { return nil }
        return .used(records: readRecords, root: readRoot)
    }

    /// Calls `body` with the record's row, if the image has one.
    func record(_ key: String, _ body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        guard let prepared else { return false }
        return read(prepared.selectRecord, key, isRecord: true, body)
    }

    /// Calls `body` with a root field's cell, if the image has one.
    func rootField(_ storageKey: String, _ body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        guard let prepared else { return false }
        return read(prepared.selectRoot, storageKey, isRecord: false, body)
    }

    private func read(_ statement: OpaquePointer, _ key: String, isRecord: Bool, _ body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        key.withCString { text in
            sqlite3_bind_text(statement, 1, text, -1, nil)
            defer { sqlite3_reset(statement) }
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else {
                if status != SQLITE_DONE, failure(status) == .unreadable { damaged = true }
                return false
            }
            guard let bytes = sqlite3_column_blob(statement, 1) else { return false }
            let used = sqlite3_column_int64(statement, 0)
            // A row no launch has touched since the one before last is gone,
            // though the writer's first batch has not deleted it yet.
            if used < generation - 1 { return false }
            if used != generation {
                if isRecord { readRecords.append(key) } else { readRoot.append(key) }
            }
            body(UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
            return true
        }
    }

    /// The slot a stored name is on a type, interning it for this store. A
    /// name with arguments is the store's to number, as a rendering, unless
    /// the build names it as a constant: the file cannot tell the two
    /// apart, and a key numbered apart widens no record. One without
    /// arguments is the build's.
    func slot(_ name: Int, on type: TypeID, _ keys: Keys) -> Slot? {
        guard name >= 0, name < names.count else { return nil }
        let table = Int(type.raw)
        if table >= slots.count { slots.append(contentsOf: repeatElement([], count: table + 1 - slots.count)) }
        if name >= slots[table].count { slots[table].append(contentsOf: repeatElement(.min, count: names.count - slots[table].count)) }
        var index = slots[table][name]
        if index == .min {
            guard let storageKey = names[name] else { return nil }
            index = (storageKey.utf8.contains(UInt8(ascii: "(")) ? keys.slot(type, storageKey, for: hold(on: keys)) : Registry.slot(type, storageKey)).index
            slots[table][name] = index
        }
        return Slot(type: type, index: index)
    }

    /// The image's hold on the numbers its rows were read under: a value a
    /// row filled stays under its number for the image's life, named or
    /// not by a live plan, as it would in the file.
    private func hold(on keys: Keys) -> Keys.Hold {
        if let hydrationHold, hydrationHold.keys === keys { return hydrationHold }
        let hold = keys.hold()
        hydrationHold = hold
        return hold
    }

    /// The type a stored name is.
    func type(_ name: Int) -> TypeID? {
        guard name >= 0, name < names.count else { return nil }
        if name >= types.count { types.append(contentsOf: repeatElement(nil, count: names.count - types.count)) }
        if let type = types[name] { return type }
        guard let text = names[name] else { return nil }
        let type = Registry.type(text)
        types[name] = type
        return type
    }

    // MARK: Writing

    /// Writes everything in one transaction, and says whether the file took
    /// it. A failure rolls the transaction back. A file too damaged to write
    /// is discarded and the work lost with it, which a cache can afford;
    /// after any other failure, a locked file or a full disk, the connection
    /// closes and the work waits to be written at the next drain.
    func write(_ work: [Persistence.Work]) -> Bool {
        if work.isEmpty { return true }
        guard let prepared else { return false }
        guard run(prepared.begin) else { return failed() }
        var good = true
        if !aged {
            good = (try? exec("""
                DELETE FROM records WHERE used < \(generation - 1);
                DELETE FROM root WHERE used < \(generation - 1);
                DELETE FROM fetches WHERE used < \(generation - 1)
                """)) != nil
            if good { good = sweepNames(prepared) }
            aged = good
        }
        for item in work {
            switch item {
            case .commit(let records, let root, let keys):
                for snapshot in records { good = put(snapshot, prepared, keys) && good }
                for field in root { good = put(field, prepared, keys) && good }
            case .fetched(let operation, let time):
                good = put(operation, time, prepared) && good
            case .used(let records, let root):
                for key in records { good = use(prepared.useRecord, key) && good }
                for field in root { good = use(prepared.useRoot, field) && good }
            case .dated(let operation):
                good = use(prepared.useFetch, operation) && good
            case .forget(let keys, let ids):
                for key in keys { good = forget(prepared.forgetRecord, key) && good }
                for id in ids { good = forget(prepared.forgetID, id) && good }
            case .invalidate:
                good = (try? exec("DELETE FROM fetches")) != nil && good
            case .freed(let slots):
                forget(slots)
            }
        }
        for id in unwritten { good = put(name: id, prepared) && good }
        guard good, run(prepared.commit) else {
            _ = run(prepared.rollback)
            return failed()
        }
        unwritten.removeAll()
        if damaged { discard() }
        return true
    }

    /// After a transaction failed: a damaged file is discarded now, not at
    /// the next read, and its work is done with; any other closes, to be
    /// opened again, and its work waits.
    private func failed() -> Bool {
        if damaged {
            discard()
            return true
        }
        close()
        return false
    }

    private func put(_ snapshot: Record.Snapshot, _ prepared: Prepared, _ keys: Keys) -> Bool {
        let record = snapshot.record
        // What hangs off the mutation and subscription roots by path is a
        // payload, read once by its caller; entities inside it have keys of
        // their own and are written as themselves.
        if record.key.hasPrefix(Disk.mutationPayloads) || record.key.hasPrefix(Disk.subscriptionPayloads) { return true }
        writer.reset()
        writer.row(snapshot, typeName: name(of:), slotName: { name(of: $0, keys) })
        return upsert(prepared.upsertRecord, record.key)
    }

    private func put(_ field: Store.RootField, _ prepared: Prepared, _ keys: Keys) -> Bool {
        if case .missing = field.value { return true }
        writer.reset()
        writer.cell(field, typeName: name(of:))
        return upsert(prepared.upsertRoot, keys.text(of: field.slot))
    }

    /// Binds the key, the generation and the row's bytes, and steps.
    private func upsert(_ statement: OpaquePointer, _ key: String) -> Bool {
        key.withCString { text in
            writer.bytes.withUnsafeBufferPointer { bytes in
                sqlite3_bind_text(statement, 1, text, -1, nil)
                sqlite3_bind_int64(statement, 2, generation)
                sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), nil)
                return run(statement)
            }
        }
    }

    private func put(_ operation: String, _ time: Double, _ prepared: Prepared) -> Bool {
        operation.withCString { text in
            sqlite3_bind_text(prepared.upsertFetch, 1, text, -1, nil)
            sqlite3_bind_int64(prepared.upsertFetch, 2, generation)
            sqlite3_bind_double(prepared.upsertFetch, 3, time)
            return run(prepared.upsertFetch)
        }
    }

    private func put(name id: Int32, _ prepared: Prepared) -> Bool {
        guard let name = names[Int(id)] else { return true }
        return name.withCString { text in
            sqlite3_bind_int64(prepared.upsertName, 1, Int64(id))
            sqlite3_bind_text(prepared.upsertName, 2, text, -1, nil)
            return run(prepared.upsertName)
        }
    }

    /// Deletes the names no row uses any more, once a launch's aging has
    /// run, so that the ids and cursors a session rendered leave the file
    /// with the rows that carried them and their ids are used again: the
    /// table is bounded by the rows. A row that does not read keeps what it
    /// names, as it keeps its place until it ages out.
    private func sweepNames(_ prepared: Prepared) -> Bool {
        var used = [Bool](repeating: false, count: names.count)
        for id in unwritten { used[Int(id)] = true }
        do {
            try each("SELECT row FROM records") { statement in
                guard let bytes = sqlite3_column_blob(statement, 0) else { return }
                var reader = RowReader(UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
                _ = reader.names(ofRow: &used)
            }
            try each("SELECT cell FROM root") { statement in
                guard let bytes = sqlite3_column_blob(statement, 0) else { return }
                var reader = RowReader(UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
                _ = reader.names(ofCell: &used)
            }
        } catch {
            return false
        }
        var good = true
        for id in names.indices where !used[id] {
            guard let name = names[id] else { continue }
            sqlite3_bind_int64(prepared.deleteName, 1, Int64(id))
            good = run(prepared.deleteName) && good
            ids.removeValue(forKey: name)
            names[id] = nil
        }
        // The table ends at its highest name in use; the holes below it are
        // used again, lowest first. What the caches knew by id may now name
        // nothing, and is learned again.
        while let last = names.last, last == nil { names.removeLast() }
        freeNames = names.indices.reversed().compactMap { names[$0] == nil ? Int32($0) : nil }
        slotNames.removeAll()
        renderedNames.removeAll()
        typeNames.removeAll()
        return good
    }

    private func forget(_ statement: OpaquePointer, _ key: String) -> Bool {
        key.withCString { text in
            sqlite3_bind_text(statement, 1, text, -1, nil)
            return run(statement)
        }
    }

    private func use(_ statement: OpaquePointer, _ key: String) -> Bool {
        key.withCString { text in
            sqlite3_bind_text(statement, 1, text, -1, nil)
            sqlite3_bind_int64(statement, 2, generation)
            return run(statement)
        }
    }

    // MARK: Names

    private func intern(_ name: String) -> Int32 {
        if let id = ids[name] { return id }
        let id: Int32
        if let reused = freeNames.popLast() {
            id = reused
            names[Int(id)] = name
            // What the caches knew of the id named another text.
            for table in slots.indices where Int(id) < slots[table].count { slots[table][Int(id)] = .min }
            if Int(id) < types.count { types[Int(id)] = nil }
        } else {
            id = Int32(names.count)
            names.append(name)
        }
        ids[name] = id
        unwritten.append(id)
        return id
    }

    private func name(of type: TypeID) -> Int32 {
        let index = Int(type.raw)
        if index >= typeNames.count { typeNames.append(contentsOf: repeatElement(-1, count: index + 1 - typeNames.count)) }
        if typeNames[index] < 0 { typeNames[index] = intern(Registry.typeName(type)) }
        return typeNames[index]
    }

    /// Forgets what it knew of slots the store freed, whose numbers it will
    /// give other texts: the next row written under one interns the new
    /// text, and a stored name whose slot was one is looked up again.
    func forget(_ freed: [Slot]) {
        var byType: [Int: Set<Int32>] = [:]
        for slot in freed where slot.index < 0 { byType[Int(slot.type.raw), default: []].insert(slot.index) }
        for (type, indices) in byType {
            if type < renderedNames.count {
                for index in indices where Int(~index) < renderedNames[type].count { renderedNames[type][Int(~index)] = -1 }
            }
            if type < slots.count {
                for name in slots[type].indices where indices.contains(slots[type][name]) { slots[type][name] = .min }
            }
        }
    }

    /// The name id of a slot's storage key, which the store's keys give for
    /// a slot the store numbered; negative for a slot that is never written.
    private func name(of slot: Slot, _ keys: Keys) -> Int32 {
        if slot.index < 0 { return name(of: slot, at: Int(~slot.index), in: &renderedNames, keys) }
        return name(of: slot, at: Int(slot.index), in: &slotNames, keys)
    }

    private func name(of slot: Slot, at index: Int, in table: inout [[Int32]], _ keys: Keys) -> Int32 {
        let type = Int(slot.type.raw)
        if type >= table.count { table.append(contentsOf: repeatElement([], count: type + 1 - table.count)) }
        if index >= table[type].count { table[type].append(contentsOf: repeatElement(-1, count: index + 1 - table[type].count)) }
        if table[type][index] == -1 {
            let storageKey = keys.text(of: slot)
            table[type][index] = Disk.requestState.contains(storageKey) ? -2 : intern(storageKey)
        }
        return table[type][index]
    }

}

/// The destructor that tells SQLite to copy a bound value.
private let copied = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
