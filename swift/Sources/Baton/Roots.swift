/// What keeps records alive is the store's, since it is a fact about data.
/// A root is an operation's selection and the record it starts from. It
/// lives while a holder keeps it, then waits in the release buffer, oldest
/// out first; a completed mutation's payload waits apart from the buffer.
/// The collector marks from the roots, the optimistic layers and the image's
/// write queue, and from nothing else, and runs when a root left or a commit
/// dropped a link.
extension Store {
    /// A root entry: the operation's selection, the record it starts from,
    /// and how many hold it.
    @MainActor
    final class Root {
        /// The operation's name and variables, as the image names it.
        let key: String
        let resolved: ResolvedSelection
        let record: Record
        fileprivate(set) var holders = 0

        init(key: String, resolved: ResolvedSelection, record: Record) {
            self.key = key
            self.resolved = resolved
            self.record = record
        }
    }

    /// The root of an operation, made on first sight: the caller retains it,
    /// or parks it in the release buffer.
    func root(_ key: String, resolved: ResolvedSelection, record: Record) -> Root {
        if let root = roots[key] { return root }
        let root = Root(key: key, resolved: resolved, record: record)
        roots[key] = root
        return root
    }

    /// Keeps the root's records alive by one holder more. A root retained
    /// after its eviction is a root again.
    func retain(_ root: Root) {
        root.holders += 1
        releaseBuffer.removeAll { $0 == root.key }
        if roots[root.key] == nil { roots[root.key] = root }
    }

    /// One holder fewer. At none the root waits in the release buffer, oldest
    /// out first, or leaves at once when nothing of it is to be buffered: a
    /// subscription's events wait for nobody. The keys of the roots pushed
    /// out are returned, so that the environment drops what it holds for
    /// them.
    func release(_ root: Root, buffering: Bool = true) -> [String] {
        root.holders -= 1
        guard root.holders <= 0 else { return [] }
        root.holders = 0
        guard buffering else {
            drop(root)
            return []
        }
        return park(root.key)
    }

    /// Parks a root in the release buffer, as a preload does by hand, and
    /// returns the keys of the roots pushed out. A root pushed out leaves,
    /// and the pass that follows may free what it kept; a root that only
    /// moved into the buffer removes nothing, and no pass runs for it.
    func park(_ key: String) -> [String] {
        releaseBuffer.removeAll { $0 == key }
        releaseBuffer.append(key)
        var evicted: [String] = []
        while releaseBuffer.count > releaseBufferSize {
            let gone = releaseBuffer.removeFirst()
            roots.removeValue(forKey: gone)
            evicted.append(gone)
        }
        if !evicted.isEmpty { scheduleCollection() }
        return evicted
    }

    /// A root that leaves at once: a subscription released closes its
    /// stream, and its events wait for nobody.
    func drop(_ root: Root) {
        roots.removeValue(forKey: root.key)
        releaseBuffer.removeAll { $0 == root.key }
        scheduleCollection()
    }

    /// Keeps a completed mutation's payload alive as a root, apart from the
    /// release buffer, so mutations push no released query out of it. A
    /// mutation's root fields are keyed by response key, so an earlier
    /// completion of an equal operation value, whose selection is the same,
    /// keeps what the latest one does, and the latest takes its place. One
    /// with other variables keeps its own: its selection may reach records
    /// the latest one's does not, through `@include`, `@skip` or an argument
    /// below the root field.
    func keepCompleted(_ root: Root) {
        completedMutations.removeAll { $0 == root.key }
        completedMutations.append(root.key)
        roots[root.key] = root
        guard completedMutations.count > releaseBufferSize else { return }
        for gone in completedMutations.prefix(completedMutations.count - releaseBufferSize) {
            roots.removeValue(forKey: gone)
        }
        completedMutations.removeFirst(completedMutations.count - releaseBufferSize)
        scheduleCollection()
    }

    /// The roots: retained, waiting in the buffer, or a completed mutation's.
    package var rootCount: Int { roots.count }

    /// Runs a pass on the next turn of the main actor; several reasons in one
    /// turn run one pass.
    func scheduleCollection() {
        guard !collectionScheduled else { return }
        collectionScheduled = true
        Task { @MainActor in
            self.collectionScheduled = false
            self.collect()
        }
    }

    /// Removes every record no retention reaches: the roots, the records an
    /// optimistic layer wrote, which stay until the layer is resolved, and the
    /// records whose rows wait to be written, so the image, which a read does
    /// not write first, is never older than memory. Returns how many were
    /// removed.
    @discardableResult
    package func collect() -> Int {
        var reachable = Set<ObjectIdentifier>()
        reachable.reserveCapacity(count)
        for root in roots.values {
            mark(root.resolved, from: root.record, into: &reachable)
        }
        for record in persistence?.unwrittenRecords(removals: imageRemovals) ?? [] {
            reachable.insert(ObjectIdentifier(record))
        }
        for layer in optimisticLayers {
            for key in layer.changes.recordKeys {
                if let record = existing(key) { reachable.insert(ObjectIdentifier(record)) }
            }
        }
        collections += 1
        return sweep(keeping: reachable)
    }
}

/// What keeps an operation's records alive: the token `retain()` returns,
/// whose end releases. A view's storage holds one for the view's life; a
/// model or a view controller holds one in a property and lets it go with
/// itself. The handle it keeps stays reachable through it.
@MainActor
public final class Retention {
    private let handle: any AnyOperationHandle

    init(_ handle: any AnyOperationHandle) {
        self.handle = handle
    }

    isolated deinit {
        handle.release()
    }
}
