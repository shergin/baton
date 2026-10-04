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
/// launch. One process uses a file at a time, and one image in it: a second
/// image made on a file another holds runs without it, as on a database of
/// another kind, and stops a debug build where it is made. `close()` and
/// the image's end hand the file over.
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
        /// The keys numbered apart, as `~index`, and their values.
        let renderedIDs: ContiguousArray<Int32>
        let renderedValues: ContiguousArray<Value>
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
        /// How many forgets the work holds.
        var forgets = 0
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
    /// How many times `removeAll()` has run. A store notes the count when it
    /// is made and hands it over with everything it asks of the image; once
    /// a removal has come after, nothing it asks is done. A removal counts
    /// itself before it clears anything, and the count is compared under the
    /// lock of what it guards, so a store's work is either cleared by the
    /// removal or refused after it.
    private let removalCount = Atomic<Int>(0)

    /// An image in the file at `url`; its directory is created when missing.
    /// The file is opened at once, off the caller's thread.
    public init(url: URL, version: String = "", sizeLimit: Int = 64 << 20) {
        self.url = url
        self.version = version
        self.sizeLimit = sizeLimit
        disk = Mutex(Disk(path: Persistence.canonicalPath(of: url), version: version, sizeLimit: sizeLimit))
        Task.detached(priority: .userInitiated) { self.drain() }
    }

    /// The file's path with its directory's symbolic links resolved, which
    /// the image opens and claims the file by: every spelling of one file
    /// names it alike, `/tmp` and `/private/tmp` among them, whether the
    /// file exists yet or not. A directory not made yet is resolved from the
    /// nearest one that exists, so nothing is created here.
    private static func canonicalPath(of url: URL) -> String {
        let file = url.standardizedFileURL
        var directory = file.deletingLastPathComponent().path
        var rest = [file.lastPathComponent]
        while true {
            if let resolved = realpath(directory, nil) {
                defer { free(resolved) }
                return rest.reversed().reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { return file.path }
            rest.append((directory as NSString).lastPathComponent)
            directory = parent
        }
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

    /// Writes what is queued, closes the file and gives it back, so a new
    /// image may take it over. Work queued later opens it again, unless
    /// another image has taken it. The new image counts as a launch, though
    /// the process is the same: the rows this launch wrote that the new
    /// image does not read age out a launch sooner. A sign-out keeps one
    /// image, removing it with `removeAll()` and handing it to the next
    /// environment, and closes nothing.
    public func close() async {
        await Task.detached(priority: .userInitiated) {
            self.drain()
            self.disk.withLock { $0.release() }
        }.value
    }

    /// Deletes the image, for a sign-out: the work queued before it is
    /// dropped and the file removed, names and argument values with it, so
    /// nothing of the session survives a failed write. A database of another
    /// kind at the path is left alone. A sign-out releases the old
    /// environment's handles, as its views going away does, removes the
    /// image, and makes a new environment over it, whose store starts a new
    /// file. A store made before the removal keeps its records in memory but
    /// reads, writes and dates nothing in the image after it, so a response
    /// that lands late for the user who signed out reaches neither the file
    /// nor the next user.
    public func removeAll() {
        removalCount.add(1, ordering: .sequentiallyConsistent)
        ages.withLock { ages in
            ages.times.removeAll()
            ages.cleared = true
        }
        pending.withLock { pending in
            pending.work.removeAll()
            pending.forgets = 0
        }
        disk.withLock { $0.erase() }
    }

    // MARK: From the main actor

    // The calls that read, write or date the image carry `removals`, the
    // count its store noted when it was made, and do nothing once another
    // removal has come.

    /// How many times the image has been removed so far, which a store notes
    /// when it is made.
    var removals: Int {
        removalCount.load(ordering: .sequentiallyConsistent)
    }

    /// Whether no removal has come since a store noted `removals`.
    private func current(_ removals: Int) -> Bool {
        removalCount.load(ordering: .sequentiallyConsistent) == removals
    }

    /// Queues what a commit changed.
    func committed(_ records: [Snapshot], root: [RootField], removals: Int) {
        enqueue(.commit(records: records, root: root), removals: removals)
    }

    /// Queues the records a payload could not edit in memory, for the image
    /// to drop: the next read misses them and fetches.
    func forget(keys: [String], ids: [String], removals: Int) {
        enqueue(.forget(keys: keys, ids: ids), removals: removals)
    }

    /// Whether a forget waits in the queue, the rows it names still in the
    /// file. One the writer has taken is done, or the image is to be
    /// discarded, before a read can take the file.
    var forgetting: Bool {
        pending.withLock { $0.forgets > 0 }
    }

    /// Notes that an operation's response just committed.
    func fetched(_ operation: String, removals: Int) {
        let time = Date().timeIntervalSince1970
        let noted = ages.withLock { ages in
            guard current(removals) else { return false }
            ages.times[operation] = time
            return true
        }
        if noted { enqueue(.fetched(operation: operation, time: time), removals: removals) }
    }

    /// How many seconds ago the operation's last response committed, in this
    /// launch or an earlier one.
    /// A time read from the image is stamped as used, once per launch, so
    /// data read every launch keeps its age and does not go stale at the
    /// next but one.
    func age(of operation: String, removals: Int) -> Double? {
        let (time, first): (Double?, Bool) = ages.withLock { ages in
            guard current(removals) else { return (nil, false) }
            return (ages.times[operation], ages.read.insert(operation).inserted)
        }
        guard let time else { return nil }
        if first { enqueue(.dated(operation: operation), removals: removals) }
        return max(0, Date().timeIntervalSince1970 - time)
    }

    /// Forgets every fetch time, so data from the image reads as stale.
    func invalidate(removals: Int) {
        let cleared = ages.withLock { ages in
            guard current(removals) else { return false }
            ages.times.removeAll()
            ages.cleared = true
            return true
        }
        if cleared { enqueue(.invalidate, removals: removals) }
    }

    /// Runs `body` holding the connection, inside one read transaction. It
    /// writes nothing first: a batch the writer is writing lands before the
    /// lock is had, and the records of a batch still queued, with those its
    /// root fields link to, are kept in memory by the collector, so a read
    /// never meets an older row than memory held. False when the file
    /// cannot be opened, and once a removal has come since the store noted
    /// `removals`.
    func reading(removals: Int, _ body: (Disk) -> Bool) -> Bool {
        var used: Work?
        let result = disk.withLock { disk in
            guard current(removals), opened(disk) else { return false }
            guard disk.beginRead() else { return false }
            let result = body(disk)
            used = disk.endRead()
            return result
        }
        if let used { enqueue(used, removals: removals) }
        return result
    }

    /// The records the queue has yet to write, which the collector keeps
    /// until it has: those whose snapshots wait, and those a waiting root
    /// field links to. The root drops its links to swept records, and a
    /// field dropped before its row is written would be read back from the
    /// row before it. A store made before the last removal has none.
    func unwrittenRecords(removals: Int) -> [Record] {
        pending.withLock { pending in
            guard current(removals) else { return [] }
            var kept: [Record] = []
            for case .commit(let records, let root) in pending.work {
                for snapshot in records { kept.append(snapshot.record) }
                for field in root {
                    switch field.value {
                    case .ref(let target): kept.append(target)
                    case .refs(let targets): for case let target? in targets { kept.append(target) }
                    default: continue
                    }
                }
            }
            return kept
        }
    }

    // MARK: The writer

    private func enqueue(_ work: Work, removals: Int) {
        let start = pending.withLock { pending in
            guard current(removals) else { return false }
            pending.work.append(work)
            if case .forget = work { pending.forgets += 1 }
            if pending.scheduled { return false }
            pending.scheduled = true
            return true
        }
        if start { Task.detached(priority: .utility) { self.drain() } }
    }

    private func take() -> [Work] {
        pending.withLock { pending in
            pending.scheduled = false
            pending.forgets = 0
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
            // An image that gave its file back takes it again for work, not
            // to be ready for it: the open its creation scheduled, or a
            // drain behind `close()`, must not take it from the next image.
            if work.isEmpty, !disk.holding { return }
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
