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
/// launch. An image is made for one store and lives as long as it: the
/// environment's end closes it and gives the file back, and the next
/// environment makes its own, on that file or another. One process uses a
/// file at a time, and one image in it: a second image made on a file
/// another holds runs without it, as on a database of another kind, and
/// stops a debug build where it is made.
public final class Persistence: Sendable {
    public let url: URL
    /// The app's own version of what it caches. An image written under
    /// another version is discarded: change it on a release whose schema
    /// gives a field another type.
    public let version: String
    /// The file size, in bytes, past which the image is discarded at launch.
    public let sizeLimit: Int

    /// One thing the main actor asked the writer to do, in order.
    enum Work: Sendable {
        case commit(records: [Record.Snapshot], root: [Store.RootField])
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
        /// Whether the writer is held: the work waits in the queue until it is
        /// let go. For the tests.
        var held = false
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

    /// An image named `name` in the app's caches directory, under the app's
    /// bundle identifier, which the system may empty when storage runs low
    /// and does not back up. On a Mac the caches directory is shared by
    /// every process of the user, so the identifier keeps two apps that both
    /// name their image `"Main"` apart; a process without one, a tool or a
    /// test runner, is kept apart by its name.
    public convenience init(name: String, version: String = "", sizeLimit: Int = 64 << 20) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let owner = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let url = caches
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent("Baton", isDirectory: true)
            .appendingPathComponent(name + ".sqlite")
        self.init(url: url, version: version, sizeLimit: sizeLimit)
    }

    /// Waits until everything committed so far is in the file: for tests, and
    /// for an app about to be suspended.
    public func flush() async {
        await Task.detached(priority: .userInitiated) { self.drain() }.value
    }

    /// Writes what is queued, closes the file and gives it back, so a new
    /// image may take it over: what the environment's end does. Work queued
    /// later opens it again, unless another image has taken it. The new image
    /// counts as a launch, though the process is the same: the rows this
    /// launch wrote that the new image does not read age out a launch sooner.
    public func close() async {
        await Task.detached(priority: .userInitiated) {
            self.drain()
            self.disk.withLock { $0.release() }
        }.value
    }

    /// Deletes the image's file, for a sign-out: the work queued before it is
    /// dropped and the file removed, names and argument values with it, so
    /// nothing of the session survives a failed write. A database of another
    /// kind at the path is left alone. The deletion is hygiene, which can be
    /// interrupted and repeated: what keeps one account's rows from the next
    /// is the image's identity, the account in its path or in its `version`.
    /// The order of a sign-out is the app's: end the environment, which
    /// closes the image and commits nothing after, remove the image, forget
    /// the credential last.
    public func removeAll() {
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

    /// Queues what a commit changed.
    func committed(_ records: [Record.Snapshot], root: [Store.RootField]) {
        enqueue(.commit(records: records, root: root))
    }

    /// Queues the records a payload could not edit in memory, for the image
    /// to drop: the next read misses them and fetches.
    func forget(keys: [String], ids: [String]) {
        enqueue(.forget(keys: keys, ids: ids))
    }

    /// What the image was told to forget and the writer has not yet dropped,
    /// which a read must not meet meanwhile: by key, until a response writes
    /// that key, and by bare id, but for the keys with the id that a
    /// response has written since (a payload with `Location:1` says nothing
    /// of `Character:1`). The store keeps one, on the main actor.
    struct Forgotten {
        private var keys: Set<String> = []
        private var ids: Set<String> = []
        private var rewritten: Set<String> = []

        var isEmpty: Bool { keys.isEmpty && ids.isEmpty }

        /// Notes what a batch told the image to forget. A record with an id
        /// that an earlier payload wrote is forgotten with the rest.
        mutating func note(keys forgottenKeys: [String], ids forgottenIDs: [String]) {
            keys.formUnion(forgottenKeys)
            ids.formUnion(forgottenIDs)
            if !forgottenIDs.isEmpty, !rewritten.isEmpty {
                rewritten = rewritten.filter { !forgottenIDs.contains(Forgotten.id(ofEntity: $0)) }
            }
        }

        /// A record a payload wrote is the store's again, by its exact key.
        mutating func wrote(_ key: String, isEntity: Bool) {
            keys.remove(key)
            if isEntity, !ids.isEmpty, ids.contains(Forgotten.id(ofEntity: key)) { rewritten.insert(key) }
        }

        mutating func clear() {
            keys.removeAll()
            ids.removeAll()
            rewritten.removeAll()
        }

        /// Whether the record's row is not to be read.
        func contains(_ record: Record) -> Bool {
            if keys.contains(record.key) { return true }
            if let id = record.entityID, ids.contains(id), !rewritten.contains(record.key) { return true }
            return false
        }

        /// The id inside an entity's key: what follows its type's name,
        /// which holds no colon.
        private static func id(ofEntity key: String) -> String {
            guard let separator = key.firstIndex(of: ":") else { return key }
            return String(key[key.index(after: separator)...])
        }
    }

    /// Whether a forget waits in the queue, the rows it names still in the
    /// file. One the writer has taken is done, or the image is to be
    /// discarded, before a read can take the file.
    var forgetting: Bool {
        pending.withLock { $0.forgets > 0 }
    }

    /// Notes that an operation's response just committed.
    func fetched(_ operation: String) {
        let time = Date().timeIntervalSince1970
        let noted = ages.withLock { ages in
            ages.times[operation] = time
            return true
        }
        if noted { enqueue(.fetched(operation: operation, time: time)) }
    }

    /// How many seconds ago the operation's last response committed, in this
    /// launch or an earlier one.
    /// A time read from the image is stamped as used, once per launch, so
    /// data read every launch keeps its age and does not go stale at the
    /// next but one.
    func age(of operation: String) -> Double? {
        let (time, first): (Double?, Bool) = ages.withLock { ages in
            return (ages.times[operation], ages.read.insert(operation).inserted)
        }
        guard let time else { return nil }
        if first { enqueue(.dated(operation: operation)) }
        return max(0, Date().timeIntervalSince1970 - time)
    }

    /// Forgets every fetch time, so data from the image reads as stale.
    func invalidate() {
        let cleared = ages.withLock { ages in
            ages.times.removeAll()
            ages.cleared = true
            return true
        }
        if cleared { enqueue(.invalidate) }
    }

    /// Runs `body` holding the connection, inside one read transaction. It
    /// writes nothing first: a batch the writer is writing lands before the
    /// lock is had, and the records of a batch still queued, with those its
    /// root fields link to, are kept in memory by the collector, so a read
    /// never meets an older row than memory held. False when the file
    /// cannot be opened.
    /// `state` is the caller's, handed through rather than captured: a
    /// variable a closure captures is boxed, and its every `inout` pass pays
    /// a dynamic exclusivity check.
    func reading<State>(_ state: inout State, _ body: (Disk, inout State) -> Bool) -> Bool {
        var used: Work?
        let result = disk.withLock { disk in
            guard opened(disk) else { return false }
            guard disk.beginRead() else { return false }
            let result = body(disk, &state)
            used = disk.endRead()
            return result
        }
        if let used { enqueue(used) }
        return result
    }

    /// Runs `body` with the writer held, so that what `body` commits is
    /// queued and not written until it returns: for the tests, which hold the
    /// window between a commit and its write open. The file is not held, so
    /// `body` may read it.
    @MainActor
    package func holdingTheWriter(_ body: () -> Void) {
        pending.withLock { $0.held = true }
        body()
        let start = pending.withLock { pending in
            pending.held = false
            if pending.work.isEmpty || pending.scheduled { return false }
            pending.scheduled = true
            return true
        }
        if start { Task.detached(priority: .utility) { self.drain() } }
    }

    /// The records the queue has yet to write, which the collector keeps
    /// until it has: those whose snapshots wait, and those a waiting root
    /// field links to. The root drops its links to swept records, and a
    /// field dropped before its row is written would be read back from the
    /// row before it. A store made before the last removal has none.
    func unwrittenRecords() -> [Record] {
        pending.withLock { pending in
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

    private func enqueue(_ work: Work) {
        let start = pending.withLock { pending in
            pending.work.append(work)
            if case .forget = work { pending.forgets += 1 }
            if pending.scheduled || pending.held { return false }
            pending.scheduled = true
            return true
        }
        if start { Task.detached(priority: .utility) { self.drain() } }
    }

    private func take() -> [Work] {
        pending.withLock { pending in
            pending.scheduled = false
            // A held writer leaves the work where it is; letting go drains.
            if pending.held { return [] }
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
