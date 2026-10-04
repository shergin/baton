import Foundation
import SQLite3

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
    /// under an interface or union ends in the record's concrete type.
    static let format: Int64 = 2
    /// Marks the file as an image, so a database of another kind is left alone.
    static let applicationID: Int64 = 0x4241_544E
    /// How many names an image may intern before it starts again: argument
    /// values make keys, and ids must stay dense, so the table only grows.
    static let nameLimit = 65_536
    /// Client fields that describe a request in flight, not data.
    static let requestState: Set<String> = ["__isLoadingNext", "__isLoadingPrevious"]
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
    private var db: OpaquePointer?
    private var retryAfter: UInt64 = 0
    /// Set when the file is another program's database: the image stays off
    /// for the process instead of asking again every second.
    private var foreign = false
    /// Whether this process has moved the generation already: a connection
    /// opened again after a failure is the same launch.
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
        let upsertFetch, upsertName: OpaquePointer
        let begin, beginReading, commit, rollback: OpaquePointer
    }

    /// Every statement prepared on the connection, finalized when it closes.
    private var statements: [OpaquePointer] = []
    private var prepared: Prepared?

    /// Names by id, and back.
    private var names: [String] = []
    private var ids: [String: Int32] = [:]
    /// Names interned since the last transaction that committed.
    private var unwritten: [Int32] = []
    /// By type, then by slot index: the name id, -1 when not asked yet, -2
    /// for a slot that is never written.
    private var slotNames: [[Int32]] = []
    /// By type: the name id of the type's name, or -1.
    private var typeNames: [Int32] = []
    /// By type, then by name id: the slot index, or -1.
    private var slots: [[Int32]] = []
    /// By name id: the type of that name.
    private var types: [TypeID?] = []

    private var scratch: [UInt8] = []
    private var readRecords: [String] = []
    private var readRoot: [String] = []

    init(path: String, version: String, sizeLimit: Int) {
        self.path = path
        self.version = version
        self.sizeLimit = sizeLimit
    }

    deinit { close() }

    // MARK: Opening

    /// Opens the file unless it is open. An unreadable file is deleted and
    /// started again; any other failure leaves the image off for a second.
    func open() -> Opening {
        if db != nil { return .already }
        if foreign { return .unavailable }
        let now = DispatchTime.now().uptimeNanoseconds
        if now < retryAfter { return .unavailable }
        for attempt in 0..<2 {
            do {
                return .opened(try connect())
            } catch .unreadable where attempt == 0 {
                discard()
            } catch .foreign {
                foreign = true
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
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
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
        // and the generation moves once per process. Rows no launch has
        // touched since the one before last go in the writer's first batch.
        try exec("BEGIN IMMEDIATE")
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

        names.removeAll()
        ids.removeAll()
        var dense = true
        try each("SELECT id, name FROM names ORDER BY id") { statement in
            guard Int(sqlite3_column_int64(statement, 0)) == names.count, let name = sqlite3_column_text(statement, 1) else {
                dense = false
                return
            }
            ids[String(cString: name)] = Int32(names.count)
            names.append(String(cString: name))
        }
        if !dense || names.count > Disk.nameLimit { throw .unreadable }
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
            // A plain insert: an id another connection took fails the batch
            // rather than renaming what every row written with it means.
            upsertName: try prepare("INSERT INTO names(id, name) VALUES(?1, ?2)"),
            begin: try prepare("BEGIN IMMEDIATE"),
            beginReading: try prepare("BEGIN"),
            commit: try prepare("COMMIT"),
            rollback: try prepare("ROLLBACK")
        )
        return times
    }

    /// Closes the connection, so another image may open the file: for a
    /// sign-out's new environment, and for tests that run one launch after
    /// another. Work that comes later opens it again.
    func release() {
        close()
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
        unwritten.removeAll()
        slotNames.removeAll()
        typeNames.removeAll()
        slots.removeAll()
        types.removeAll()
    }

    /// Deletes the file and its journal: an image that cannot be read is a
    /// miss, never a migration.
    private func discard() {
        close()
        for suffix in ["", "-wal", "-shm"] {
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

    /// The slot a stored name is on a type, interning it for this process.
    func slot(_ name: Int, on type: TypeID) -> Slot? {
        guard name >= 0, name < names.count else { return nil }
        let table = Int(type.raw)
        if table >= slots.count { slots.append(contentsOf: repeatElement([], count: table + 1 - slots.count)) }
        if name >= slots[table].count { slots[table].append(contentsOf: repeatElement(-1, count: names.count - slots[table].count)) }
        var index = slots[table][name]
        if index < 0 {
            index = Registry.slot(type, names[name]).index
            slots[table][name] = index
        }
        return Slot(type: type, index: index)
    }

    /// The type a stored name is.
    func type(_ name: Int) -> TypeID? {
        guard name >= 0, name < names.count else { return nil }
        if name >= types.count { types.append(contentsOf: repeatElement(nil, count: names.count - types.count)) }
        if let type = types[name] { return type }
        let type = Registry.type(names[name])
        types[name] = type
        return type
    }

    // MARK: Writing

    /// Writes everything in one transaction. A failure rolls it back and the
    /// work is lost, which a cache can afford.
    func write(_ work: [Persistence.Work]) {
        guard !work.isEmpty, let prepared else { return }
        guard run(prepared.begin) else {
            // A file too damaged to begin a transaction in is discarded now,
            // not at the next read.
            if damaged { discard() }
            return
        }
        var good = true
        if !aged {
            good = (try? exec("""
                DELETE FROM records WHERE used < \(generation - 1);
                DELETE FROM root WHERE used < \(generation - 1);
                DELETE FROM fetches WHERE used < \(generation - 1)
                """)) != nil
            aged = good
        }
        for item in work {
            switch item {
            case .commit(let records, let root):
                for snapshot in records { good = put(snapshot, prepared) && good }
                for field in root { good = put(field, prepared) && good }
            case .fetched(let operation, let time):
                good = put(operation, time, prepared) && good
            case .used(let records, let root):
                for key in records { good = use(prepared.useRecord, key) && good }
                for field in root { good = use(prepared.useRoot, field) && good }
            case .invalidate:
                good = (try? exec("DELETE FROM fetches")) != nil && good
            case .removeAll:
                good = (try? exec("DELETE FROM records; DELETE FROM root; DELETE FROM fetches")) != nil && good
            }
        }
        for id in unwritten { good = put(name: id, prepared) && good }
        if good, run(prepared.commit) {
            unwritten.removeAll()
        } else {
            _ = run(prepared.rollback)
        }
        if damaged { discard() }
    }

    private func put(_ snapshot: Persistence.Snapshot, _ prepared: Prepared) -> Bool {
        let record = snapshot.record
        // What hangs off the mutation and subscription roots by path is a
        // payload, read once by its caller; entities inside it have keys of
        // their own and are written as themselves.
        if record.key.hasPrefix(Disk.mutationPayloads) || record.key.hasPrefix(Disk.subscriptionPayloads) { return true }
        scratch.removeAll(keepingCapacity: true)
        scratch.append((snapshot.deleted ? 1 : 0) | (record.isEntity ? 2 : 0))
        append(varint: UInt64(name(of: record.type)))
        for index in snapshot.values.indices {
            if case .missing = snapshot.values[index] { continue }
            let name = name(of: Slot(type: record.type, index: Int32(index)))
            if name < 0 { continue }
            append(varint: UInt64(name))
            append(snapshot.values[index], error: snapshot.errors?[Int32(index)])
        }
        return upsert(prepared.upsertRecord, record.key)
    }

    private func put(_ field: Persistence.RootField, _ prepared: Prepared) -> Bool {
        if case .missing = field.value { return true }
        scratch.removeAll(keepingCapacity: true)
        append(field.value, error: field.error)
        return upsert(prepared.upsertRoot, Registry.storageKey(field.slot))
    }

    /// Binds the key, the generation and the scratch bytes, and steps.
    private func upsert(_ statement: OpaquePointer, _ key: String) -> Bool {
        key.withCString { text in
            scratch.withUnsafeBufferPointer { bytes in
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
        names[Int(id)].withCString { text in
            sqlite3_bind_int64(prepared.upsertName, 1, Int64(id))
            sqlite3_bind_text(prepared.upsertName, 2, text, -1, nil)
            return run(prepared.upsertName)
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
        let id = Int32(names.count)
        names.append(name)
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

    /// The name id of a slot's storage key; negative for a slot that is never
    /// written.
    private func name(of slot: Slot) -> Int32 {
        let table = Int(slot.type.raw)
        let index = Int(slot.index)
        if table >= slotNames.count { slotNames.append(contentsOf: repeatElement([], count: table + 1 - slotNames.count)) }
        if index >= slotNames[table].count { slotNames[table].append(contentsOf: repeatElement(-1, count: index + 1 - slotNames[table].count)) }
        if slotNames[table][index] == -1 {
            let storageKey = Registry.storageKey(slot)
            slotNames[table][index] = Disk.requestState.contains(storageKey) ? -2 : intern(storageKey)
        }
        return slotNames[table][index]
    }

    // MARK: Encoding

    private func append(varint value: UInt64) {
        var value = value
        while value >= 0x80 {
            scratch.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        scratch.append(UInt8(truncatingIfNeeded: value))
    }

    private func append(_ string: String) {
        var string = string
        string.withUTF8 { bytes in
            append(varint: UInt64(bytes.count))
            scratch.append(contentsOf: bytes)
        }
    }

    /// A link is the target's type, whether it is an entity, and its key; a
    /// null entry of a list is a zero.
    private func append(link target: Record?) {
        guard let target else {
            scratch.append(0)
            return
        }
        append(varint: UInt64(name(of: target.type) + 1) << 1 | (target.isEntity ? 1 : 0))
        append(target.key)
    }

    /// A value is a tag and its payload; the tag's high bit says a field
    /// error follows.
    private func append(_ value: Value, error: FieldError?) {
        let flag: UInt8 = error == nil ? 0 : RowTag.hasError
        switch value {
        case .missing, .null:
            scratch.append(RowTag.null | flag)
        case .bool(let bool):
            scratch.append((bool ? RowTag.yes : RowTag.no) | flag)
        case .int(let int):
            scratch.append(RowTag.int | flag)
            append(varint: UInt64(bitPattern: Int64((int << 1) ^ (int >> 63))))
        case .double(let double):
            scratch.append(RowTag.double | flag)
            withUnsafeBytes(of: double.bitPattern.littleEndian) { scratch.append(contentsOf: $0) }
        case .string(let string):
            scratch.append(RowTag.string | flag)
            append(string)
        case .ref(let target):
            scratch.append(RowTag.ref | flag)
            append(link: target)
        case .refs(let targets):
            scratch.append(RowTag.refs | flag)
            append(varint: UInt64(targets.count))
            for target in targets { append(link: target) }
        case .list(let values):
            scratch.append(RowTag.list | flag)
            append(varint: UInt64(values.count))
            for value in values { append(value, error: nil) }
        }
        if let error {
            append(error.message)
            append(error.path)
        }
    }
}

/// The tags of a stored value.
enum RowTag {
    static let null: UInt8 = 0
    static let no: UInt8 = 1
    static let yes: UInt8 = 2
    static let int: UInt8 = 3
    static let double: UInt8 = 4
    static let string: UInt8 = 5
    static let ref: UInt8 = 6
    static let refs: UInt8 = 7
    static let list: UInt8 = 8
    static let hasError: UInt8 = 0x80
}

/// The destructor that tells SQLite to copy a bound value.
private let copied = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
