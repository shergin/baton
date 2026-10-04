import Foundation
import Synchronization

/// The store's image on disk: the records the server has told the store
/// about, written behind every commit and read back when the store is asked
/// for data it does not hold. One SQLite file through the system library.
///
/// Memory stays the truth: a read from the image fills only what memory
/// lacks. The image is a cache: a file of another format or version, a
/// corrupt file and a file over its size limit are deleted and started again,
/// and a record that goes a whole session unread is dropped at the next
/// launch. One process uses a file at a time.
public final class Persistence: Sendable {
    public let url: URL
    /// The app's own version of what it caches. An image written under
    /// another version is discarded: change it on a release whose schema
    /// gives a field another type.
    public let version: String
    /// The file size, in bytes, past which the image is discarded at launch.
    public let sizeLimit: Int

    /// What a commit hands the writer for one changed record: the record and
    /// its values at that moment. Taken on the main actor at the cost of an
    /// array retain; encoded off it.
    struct Snapshot: Sendable {
        let record: Record
        let values: ContiguousArray<Value>
        let errors: [Int32: FieldError]?
        let deleted: Bool
    }

    /// A changed field of the query root, which is stored a row per field.
    struct RootField: Sendable {
        let slot: Slot
        let value: Value
        let error: FieldError?
    }

    /// One thing the main actor asked the writer to do, in order.
    enum Work: Sendable {
        case commit(records: [Snapshot], root: [RootField])
        case fetched(operation: String, time: Double)
        /// Rows a read found carrying an older generation.
        case used(records: [String], root: [String])
        /// A fetch time this launch read, which keeps it for the next.
        case dated(operation: String)
        /// Records a server's payload changed in a way memory could not
        /// apply, by key, and by bare id under every type the image names.
        case forget(keys: [String], ids: [String])
        case invalidate
    }

    private struct Pending: Sendable {
        var work: [Work] = []
        var scheduled = false
    }

    /// When each operation last committed a response, by the wall clock.
    private struct Ages: Sendable {
        var times: [String: Double] = [:]
        /// The operations whose time this launch read and stamped.
        var read: Set<String> = []
        /// Set by an invalidation or a removal that ran before the file's
        /// own times were loaded, so the load does not bring them back.
        var cleared = false
    }

    private let disk: Mutex<Disk>
    private let pending = Mutex(Pending())
    private let ages = Mutex(Ages())

    /// An image in the file at `url`; its directory is created when missing.
    /// The file is opened at once, off the caller's thread.
    public init(url: URL, version: String = "", sizeLimit: Int = 64 << 20) {
        self.url = url
        self.version = version
        self.sizeLimit = sizeLimit
        disk = Mutex(Disk(path: url.path, version: version, sizeLimit: sizeLimit))
        Task.detached(priority: .userInitiated) { self.drain() }
    }

    /// An image named `name` in the app's caches directory, which the system
    /// may empty when storage runs low and does not back up.
    public convenience init(name: String, version: String = "", sizeLimit: Int = 64 << 20) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("Baton", isDirectory: true).appendingPathComponent(name + ".sqlite")
        self.init(url: url, version: version, sizeLimit: sizeLimit)
    }

    /// Waits until everything committed so far is in the file: for tests, and
    /// for an app about to be suspended.
    public func flush() async {
        await Task.detached(priority: .userInitiated) { self.drain() }.value
    }

    /// Writes what is queued and closes the file: before a new environment
    /// takes it over, as at a sign-out. Work queued later opens it again.
    public func close() async {
        await Task.detached(priority: .userInitiated) {
            self.drain()
            self.disk.withLock { $0.release() }
        }.value
    }

    /// Deletes the image, for a sign-out: the work queued before it is
    /// dropped and the file removed, names and argument values with it, so
    /// nothing of the session survives a failed write. Records in memory are
    /// untouched; what the store commits afterwards starts a new file. A
    /// sign-out releases the old environment's handles, as its views going
    /// away does, removes the image, and makes a new environment.
    public func removeAll() {
        ages.withLock { ages in
            ages.times.removeAll()
            ages.cleared = true
        }
        pending.withLock { $0.work.removeAll() }
        disk.withLock { $0.erase() }
    }

    // MARK: From the main actor

    /// Queues what a commit changed.
    func committed(_ records: [Snapshot], root: [RootField]) {
        enqueue(.commit(records: records, root: root))
    }

    /// Queues the records a payload could not edit in memory, for the image
    /// to drop: the next read misses them and fetches.
    func forget(keys: [String], ids: [String]) {
        enqueue(.forget(keys: keys, ids: ids))
    }

    /// Notes that an operation's response just committed.
    func fetched(_ operation: String) {
        let time = Date().timeIntervalSince1970
        ages.withLock { $0.times[operation] = time }
        enqueue(.fetched(operation: operation, time: time))
    }

    /// How many seconds ago the operation's last response committed, in this
    /// launch or an earlier one.
    /// A time read from the image is stamped as used, once per launch, so
    /// data read every launch keeps its age and does not go stale at the
    /// next but one.
    func age(of operation: String) -> Double? {
        let (time, first) = ages.withLock { ages in
            (ages.times[operation], ages.read.insert(operation).inserted)
        }
        guard let time else { return nil }
        if first { enqueue(.dated(operation: operation)) }
        return max(0, Date().timeIntervalSince1970 - time)
    }

    /// Forgets every fetch time, so data from the image reads as stale.
    func invalidate() {
        ages.withLock { ages in
            ages.times.removeAll()
            ages.cleared = true
        }
        enqueue(.invalidate)
    }

    /// Runs `body` holding the connection, inside one read transaction. It
    /// writes nothing first: a batch the writer is writing lands before the
    /// lock is had, and the records of a batch still queued are kept in
    /// memory by the collector, so a read never meets an older row than
    /// memory held. False when the file cannot be opened.
    func reading(_ body: (Disk) -> Bool) -> Bool {
        var used: Work?
        let result = disk.withLock { disk in
            guard opened(disk) else { return false }
            guard disk.beginRead() else { return false }
            let result = body(disk)
            used = disk.endRead()
            return result
        }
        if let used { enqueue(used) }
        return result
    }

    /// The records whose snapshots wait in the queue, which the collector
    /// keeps until they are written.
    func unwrittenRecords() -> [Record] {
        pending.withLock { pending in
            pending.work.flatMap { work -> [Record] in
                guard case .commit(let records, _) = work else { return [] }
                return records.map(\.record)
            }
        }
    }

    // MARK: The writer

    private func enqueue(_ work: Work) {
        let start = pending.withLock { pending in
            pending.work.append(work)
            if pending.scheduled { return false }
            pending.scheduled = true
            return true
        }
        if start { Task.detached(priority: .utility) { self.drain() } }
    }

    private func take() -> [Work] {
        pending.withLock { pending in
            pending.scheduled = false
            let work = pending.work
            pending.work.removeAll(keepingCapacity: true)
            return work
        }
    }

    /// Opens the file if needed and writes everything queued, in one
    /// transaction. Work queued while the file cannot be opened is dropped.
    private func drain() {
        disk.withLock { disk in
            let work = take()
            guard opened(disk) else {
                // Work the file could not take is lost: the image is behind.
                if !work.isEmpty { disk.markBehind() }
                return
            }
            disk.write(work)
        }
    }

    private func opened(_ disk: Disk) -> Bool {
        switch disk.open() {
        case .already:
            return true
        case .unavailable:
            return false
        case .opened(let times):
            ages.withLock { ages in
                if ages.cleared { return }
                for (operation, time) in times where ages.times[operation] == nil { ages.times[operation] = time }
            }
            return true
        }
    }
}
