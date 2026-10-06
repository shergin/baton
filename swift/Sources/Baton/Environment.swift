import Foundation

/// Store plus transport plus configuration, in Relay's sense. One per backend,
/// injected through SwiftUI's environment as `\.baton`. It also owns the
/// operations' lifetime: retained handles and the release buffer are the roots
/// that keep records alive.
@MainActor
public final class Environment {
    public let store: Store
    public let transport: any Transport
    /// The transport subscriptions run over, when the backend has one.
    public let subscriptions: (any SubscriptionTransport)?

    /// How many released queries keep their data alive, oldest out first;
    /// as many completed mutations keep theirs, apart from them.
    public let releaseBufferSize: Int
    /// How long a fetched response stays fresh; `nil` means forever.
    public var queryCacheExpiration: Duration?
    /// Called when a `@required(action: LOG)` field is null: the record and
    /// Relay's path. Debug builds print by default.
    public var requiredFieldMissing: ((Record, String) -> Void)?

    private var handles: [AnyHashable: any AnyOperationHandle] = [:]
    private var releaseBuffer: [AnyHashable] = []
    /// The mutations that completed, oldest first and one per operation value.
    private var completedMutations: [CompletedMutation] = []
    private var collectionScheduled = false
    /// How many collections have run; for tests and benchmarks.
    package private(set) var collections = 0

    public init(transport: any Transport, subscriptions: (any SubscriptionTransport)? = nil, store: Store = Store(), releaseBufferSize: Int = 10) {
        self.store = store
        self.transport = transport
        self.subscriptions = subscriptions
        self.releaseBufferSize = releaseBufferSize
        store.environment = self
        #if DEBUG
        requiredFieldMissing = { record, path in
            print("Baton: the @required field \(path) of \(record.key) is null; its lens reads as null")
        }
        #endif
    }

    /// An environment over HTTP. With `persistence`, the store keeps an image
    /// on disk and a launch renders from it before the network answers.
    public convenience init(url: URL, headers: [String: String] = [:], subscriptions: (any SubscriptionTransport)? = nil, persistence: Persistence? = nil, releaseBufferSize: Int = 10) {
        self.init(transport: URLSessionTransport(url: url, headers: headers), subscriptions: subscriptions, store: Store(persistence: persistence), releaseBufferSize: releaseBufferSize)
    }

    /// The handle for an operation value, shared by every view that holds an
    /// equal value. The policy is applied on every attach.
    public func handle<Op: Query>(for operation: Op, fetchPolicy: FetchPolicy = .default) -> OperationHandle<Op> {
        let key = AnyHashable(operation)
        let handle: OperationHandle<Op>
        if let existing = handles[key] as? OperationHandle<Op> {
            handle = existing
        } else {
            // Registered as a root until its first release; the caller retains it.
            handle = OperationHandle(operation: operation, environment: self)
            handles[key] = handle
        }
        handle.apply(fetchPolicy)
        return handle
    }

    /// The handle for a subscription value, shared by equal values; a root
    /// while retained.
    public func subscriptionHandle<Op: Subscription>(for operation: Op) -> SubscriptionHandle<Op> {
        let key = AnyHashable(operation)
        if let existing = handles[key] as? SubscriptionHandle<Op> { return existing }
        let handle = SubscriptionHandle(operation: operation, environment: self)
        handles[key] = handle
        return handle
    }

    /// Starts fetching before any view asks; the handle waits in the release
    /// buffer for a view to attach, and that attach makes no request of its
    /// own.
    @discardableResult
    public func preload<Op: Query>(_ operation: Op, fetchPolicy: FetchPolicy = .default) -> OperationHandle<Op> {
        let handle = handle(for: operation, fetchPolicy: fetchPolicy)
        // Only a fetch the preload made can serve the first attach.
        handle.preloaded = handle.isFetching
        if handle.retainCount == 0 { park(handle.key) }
        return handle
    }

    /// Settles again the phases a commit's field errors or nulls can change:
    /// those of retained `@throwOnFieldError` and bubbling operations.
    func reevaluate() {
        for handle in handles.values where handle.retainCount > 0 {
            handle.reevaluate()
        }
    }

    /// Marks every handle's data stale. Retained handles refetch at once; the
    /// data stays visible until the response commits.
    public func invalidate() {
        store.invalidate()
        for handle in handles.values where handle.retainCount > 0 {
            handle.refetchIfStale()
        }
    }

    private func request<Op: Operation>(_ operation: Op.Type, variables: Variables) -> Request {
        Request(
            operationName: Op.name,
            text: Op.text,
            persistedID: Op.persistedID,
            variables: variables,
            errorBehavior: Op.errorBehavior,
            incremental: Op.hasDeferred
        )
    }

    /// Fetches an operation and commits the response; the handle, if any,
    /// follows. `firstPart` runs after the first part of a deferred response
    /// commits, so a view renders before the rest arrives. An operation with
    /// `@throwOnFieldError` throws the field errors its handle fails on.
    public func fetch<Op: Query>(_ operation: Op, firstPart: (() -> Void)? = nil) async throws {
        let committed = try await fetch(Op.self, variables: operation.variables, resolved: Op.plan.resolve(operation.variables), firstPart: firstPart.map { firstPart in { _ in firstPart() } })
        guard Op.throwsOnFieldError else { return }
        // The handle's reading: the operation's own selection, where an error
        // inside a spread is the fragment's to weigh, and the errors the
        // response carried with no field to hold them.
        let anchor = Anchor(record: store.root, variables: operation.variables, store: store)
        let errors = committed.unplaced + Op.Data.fieldErrors(anchor)
        if !errors.isEmpty { throw FieldErrors(errors) }
    }

    /// What a commit left for the operation's reading besides its records:
    /// the field errors no `@catch` handled, and those no field in the store
    /// holds.
    struct Committed {
        var uncaught: [FieldError] = []
        var unplaced: [FieldError] = []

        mutating func add(_ changes: ChangeSet) {
            uncaught.append(contentsOf: changes.uncaughtFieldErrors)
            unplaced.append(contentsOf: changes.unplacedErrors)
        }

        /// A part the server could not deliver: its errors count once each.
        mutating func add(_ failure: Ingest.FailedPart) {
            uncaught.append(contentsOf: failure.uncaught)
            unplaced.append(contentsOf: failure.changes.unplacedErrors)
        }

        mutating func add(_ other: Committed) {
            uncaught.append(contentsOf: other.uncaught)
            unplaced.append(contentsOf: other.unplaced)
        }
    }

    /// The one door from a payload to slots. The payload is read by the plan
    /// off the main actor into a change set, and the change set is committed
    /// here as a server batch at the root the operation hangs off. A query's
    /// fetch, a deferred stream's first part, a mutation, a subscription's
    /// event and a page all pass through it; each keeps its own rule for a
    /// caller cancelled on the way: a query's fetch checks before the
    /// commit, so a response superseded while it was read never lands, a
    /// mutation does not, since the server applied it, and a subscription
    /// commits until its task ends. Later steps stand here: an ended store
    /// refuses, the commit stamps the operation's age, a report is raised.
    /// `complete` says whether the payload must answer every field the plan
    /// selects, as a server's response does; one committed by hand may not.
    func commit(_ payload: Data, plan: ResolvedSelection, root: String, replacing layer: UUID? = nil, checkingCancellation: Bool = true, complete: Bool = true) async throws -> Committed {
        let changes = try await Ingest.normalized(payload, plan: plan, rootKey: root, complete: complete)
        if checkingCancellation { try Task.checkCancellation() }
        return commit(changes, replacing: layer)
    }

    /// The door's lower half: a change set committed as a server batch. The
    /// parts of a deferred stream after the first arrive here as the change
    /// sets the delivery assembled.
    func commit(_ changes: ChangeSet, replacing layer: UUID? = nil) -> Committed {
        store.commit(changes, replacingOptimistic: layer)
        var committed = Committed()
        committed.add(changes)
        return committed
    }

    /// Fetches with a plan already resolved, as a handle holds it. The field
    /// errors are the handle's to weigh, so none is thrown; `firstPart` is
    /// handed what the first part committed besides its records.
    func fetch<Op: Query>(_ operation: Op, resolved: ResolvedSelection, firstPart: ((Committed) -> Void)? = nil) async throws -> Committed {
        try await fetch(Op.self, variables: operation.variables, resolved: resolved, firstPart: firstPart)
    }

    /// Commits a payload for an operation that some other road delivered: a
    /// REST response in the operation's shape, a socket's tick, a preview's
    /// fixture, a test's seed. The payload is read by the operation's plan
    /// and committed as a fetch's response is, through the one door, at the
    /// root of the operation's kind: the records merge, the connections and
    /// the edge directives apply, and the image is written. A payload may
    /// carry part of what the operation selects; what it leaves out stays as
    /// it was. Under `@throwOnFieldError` the field errors no `@catch`
    /// handled are thrown, as a fetch throws them.
    public func commitPayload<Op: Operation>(_ operation: Op, _ payload: Data) async throws {
        let resolved = Op.plan.resolve(operation.variables)
        let committed = try await commit(payload, plan: resolved, root: Self.rootKey(of: Op.self), checkingCancellation: false, complete: false)
        if Op.throwsOnFieldError, !committed.uncaught.isEmpty { throw FieldErrors(committed.uncaught) }
    }

    /// The record an operation's payload hangs off, by the operation's kind.
    private static func rootKey<Op: Operation>(of operation: Op.Type) -> String {
        if operation is any Mutation.Type { return Store.mutationRootKey }
        if operation is any Subscription.Type { return Store.subscriptionRootKey }
        return Store.rootKey
    }

    /// Fetches an operation by its type and variables and commits the response.
    /// No handle and no root come of it: refetches and pagination run this way,
    /// and the records they fill stay alive through whatever reaches them.
    /// Returns the field errors no `@catch` handled.
    @discardableResult
    public func fetch<Op: Query>(_ operation: Op.Type, variables: Variables, firstPart: (() -> Void)? = nil) async throws -> [FieldError] {
        try await fetch(operation, variables: variables, resolved: Op.plan.resolve(variables), firstPart: firstPart.map { firstPart in { _ in firstPart() } }).uncaught
    }

    private func fetch<Op: Query>(_ operation: Op.Type, variables: Variables, resolved: ResolvedSelection, firstPart: ((Committed) -> Void)?) async throws -> Committed {
        let request = request(Op.self, variables: variables)
        if !Op.hasDeferred {
            // A fetch superseded while its response was on the way or being
            // read must not land after the one that replaced it.
            return try await commit(try await transport.execute(request), plan: resolved, root: Store.rootKey)
        }
        var committed = Committed()
        var delivery = Delivery(store: store, resolved: resolved)
        var first = true
        for try await part in transport.stream(request) {
            if first {
                first = false
                let opening = try await Ingest.normalizedFirstPart(part, plan: resolved, rootKey: Store.rootKey, complete: true)
                try Task.checkCancellation()
                committed.add(commit(opening.changes))
                delivery.announce(opening.pending)
                firstPart?(committed)
                if !opening.hasNext { break }
                continue
            }
            let incremental = try await Ingest.incrementalPart(part)
            delivery.announce(incremental.pending)
            let changes = try await Ingest.normalized(delivery.objects(of: incremental))
            let failures = delivery.failures(of: incremental)
            try Task.checkCancellation()
            for change in changes { committed.add(commit(change)) }
            for failure in failures {
                _ = commit(failure.changes)
                committed.add(failure)
            }
            if !incremental.hasNext { break }
        }
        return committed
    }

    /// Fetches a page of a connection: the loading flag on the connection
    /// record is set for the duration, and the commit merges the page.
    func paginate<Op: Query>(_ operation: Op.Type, variables: Variables, connection: Record, loading: Slot) async throws {
        store.local { batch in store.set(connection, loading, .bool(true), &batch) }
        defer { store.local { batch in store.set(connection, loading, .bool(false), &batch) } }
        _ = try await fetch(operation, variables: variables)
    }

    /// Commits a mutation. The optimistic response, if any, is ingested with the
    /// mutation's own plan and applied as a layer first, on the main actor, so
    /// the layer shows in the turn of the call; the server's payload is
    /// ingested off it and then replaces the layer in one batch, or the layer
    /// is reverted on failure.
    /// The data returned reads the mutation root: its payload stays alive
    /// until `releaseBufferSize` completions of other operation values follow
    /// it, and then reads only the records other roots keep. A completion of
    /// an equal value, the same name and variables, takes its place.
    public func mutate<Op: Mutation>(_ operation: Op, optimistic: Variable? = nil) async throws -> Op.Data {
        let resolved = Op.plan.resolve(operation.variables)
        var layer: UUID?
        if let optimistic {
            let json = Data(("{\"data\":" + optimistic.json + "}").utf8)
            let changes = try Ingest.normalize(json, plan: resolved, rootKey: Store.mutationRootKey)
            layer = store.applyOptimistic(changes)
        }
        let uncaught: [FieldError]
        do {
            // The request runs in a task of its own, which the caller's
            // cancellation does not reach: a server that received the
            // mutation applies it, so its payload commits whoever stopped
            // waiting, and no cancellation check stands before the commit.
            let request = request(Op.self, variables: operation.variables)
            let transport = transport
            let data = try await Task { try await transport.execute(request) }.value
            uncaught = try await commit(data, plan: resolved, root: Store.mutationRootKey, replacing: layer, checkingCancellation: false).uncaught
        } catch {
            if let layer { store.revertOptimistic(layer) }
            throw error
        }
        keep(CompletedMutation(key: AnyHashable(operation), store: store, resolved: resolved))
        if Op.throwsOnFieldError, !uncaught.isEmpty { throw FieldErrors(uncaught) }
        return Op.Data(anchor: Anchor(record: store.mutationRoot, variables: operation.variables, store: store))
    }

    /// The events of a subscription, as the transport delivers them.
    func subscribe<Op: Subscription>(_ operation: Op) -> AsyncThrowingStream<Data, any Error> {
        guard let subscriptions else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: EnvironmentError.noSubscriptionTransport)
            }
        }
        return subscriptions.subscribe(request(Op.self, variables: operation.variables))
    }

    // MARK: Lifetime

    func didRetain(_ handle: any AnyOperationHandle) {
        releaseBuffer.removeAll { $0 == handle.key }
        // A handle retained after eviction becomes a root again.
        if handles[handle.key] == nil { handles[handle.key] = handle }
    }

    func didRelease(_ handle: any AnyOperationHandle) {
        park(handle.key)
    }

    /// A subscription released: its stream closed, it leaves the roots at once.
    func didEnd(_ handle: any AnyOperationHandle) {
        handles.removeValue(forKey: handle.key)
        scheduleCollection()
    }

    private func park(_ key: AnyHashable) {
        releaseBuffer.removeAll { $0 == key }
        releaseBuffer.append(key)
        while releaseBuffer.count > releaseBufferSize {
            let evicted = releaseBuffer.removeFirst()
            handles[evicted]?.cancel()
            handles.removeValue(forKey: evicted)
        }
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
    private func keep(_ completed: CompletedMutation) {
        completedMutations.removeAll { $0.key == completed.key }
        completedMutations.append(completed)
        guard completedMutations.count > releaseBufferSize else { return }
        completedMutations.removeFirst(completedMutations.count - releaseBufferSize)
        scheduleCollection()
    }

    /// Handles that are roots for collection: retained or buffered.
    package var rootCount: Int { handles.count }

    private func scheduleCollection() {
        guard !collectionScheduled else { return }
        collectionScheduled = true
        Task { @MainActor in
            self.collectionScheduled = false
            self.collect()
        }
    }

    /// Removes every record no root reaches. Returns how many were removed.
    /// For the tests and the benchmarks, until the store owns its collector.
    @discardableResult
    package func collect() -> Int {
        var reachable = Set<ObjectIdentifier>()
        reachable.reserveCapacity(store.count)
        for handle in handles.values {
            handle.mark(into: &reachable)
        }
        for completed in completedMutations {
            completed.mark(into: &reachable)
        }
        // Records whose rows wait to be written stay, so the image, which a
        // read does not write first, is never older than memory.
        for record in store.persistence?.unwrittenRecords(removals: store.imageRemovals) ?? [] {
            reachable.insert(ObjectIdentifier(record))
        }
        // Records an optimistic layer wrote stay until the layer is resolved.
        for layer in store.optimisticLayers {
            for key in layer.changes.recordKeys {
                if let record = store.existing(key) { reachable.insert(ObjectIdentifier(record)) }
            }
        }
        collections += 1
        return store.sweep(keeping: reachable)
    }

    /// A placeholder for views outside any `.environment(\.baton, …)`.
    package static let unconfigured = Environment(transport: UnconfiguredTransport())

    /// The environment a view sees: the injected one, or the placeholder.
    package static func resolve(_ injected: Environment?) -> Environment { injected ?? unconfigured }
}

struct UnconfiguredTransport: Transport {
    func execute(_ request: Request) async throws -> Data {
        throw EnvironmentError.notInjected
    }
}
