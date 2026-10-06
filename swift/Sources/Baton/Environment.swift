import Foundation

/// Store plus transport plus configuration, in Relay's sense. One per backend,
/// injected through SwiftUI's environment as `\.baton`. It holds the live
/// side of the operations: their handles, with the fetches in flight; what
/// keeps records alive is the store's.
@MainActor
public final class Environment {
    public let store: Store
    public let transport: any Transport
    /// The transport subscriptions go through, when one is given: a socket, or
    /// another that streams events.
    public let subscriptions: (any Transport)?

    /// Called when a `@required(action: LOG)` field is null: the record and
    /// Relay's path. Debug builds print by default.
    public var requiredFieldMissing: ((Record, String) -> Void)?

    /// The handles, by the operation's key, for as long as their roots are
    /// the store's: equal operation values share one.
    private var handles: [String: any AnyOperationHandle] = [:]
    /// Whether the session has ended: every later call fails with
    /// `EnvironmentError.gone`, and what is still held says so.
    public private(set) var ended = false

    public init(transport: any Transport, subscriptions: (any Transport)? = nil, store: Store = Store()) {
        self.store = store
        self.transport = transport
        self.subscriptions = subscriptions
        store.phasesNeedSettling = { [weak self] in self?.reevaluate() }
        #if DEBUG
        requiredFieldMissing = { record, path in
            print("Baton: the @required field \(path) of \(record.key) is null; its lens reads as null")
        }
        #endif
    }

    /// An environment over HTTP. With `persistence`, the store keeps an image
    /// on disk and a launch renders from it before the network answers;
    /// `cacheExpiration` is the store's default for operations that state
    /// none of their own.
    public convenience init(url: URL, headers: [String: String] = [:], subscriptions: (any Transport)? = nil, persistence: Persistence? = nil, cacheExpiration: Duration? = nil, releaseBufferSize: Int = 10) {
        self.init(transport: URLSessionTransport(url: url, headers: headers), subscriptions: subscriptions, store: Store(persistence: persistence, cacheExpiration: cacheExpiration, releaseBufferSize: releaseBufferSize))
    }

    /// The handle for an operation value, shared by every view that holds an
    /// equal value. The policy is applied on every attach.
    public func handle<Op: Query>(for operation: Op, fetchPolicy: FetchPolicy = .default) -> OperationHandle<Op> {
        let key = Op.name + operation.variables.json
        let handle: OperationHandle<Op>
        if let existing = handles[key] as? OperationHandle<Op> {
            handle = existing
        } else {
            // A root until its first release; the caller retains it.
            handle = OperationHandle(operation: operation, key: key, environment: self)
            handles[key] = handle
        }
        handle.apply(fetchPolicy)
        return handle
    }

    /// The handle for a subscription value, shared by equal values; a root
    /// while retained.
    public func subscriptionHandle<Op: Subscription>(for operation: Op) -> SubscriptionHandle<Op> {
        let key = Op.name + operation.variables.json
        if let existing = handles[key] as? SubscriptionHandle<Op> { return existing }
        let handle = SubscriptionHandle(operation: operation, key: key, environment: self)
        handles[key] = handle
        return handle
    }

    /// Starts fetching before any view asks; the root waits in the release
    /// buffer for a view to attach, and that attach makes no request of its
    /// own.
    @discardableResult
    public func preload<Op: Query>(_ operation: Op, fetchPolicy: FetchPolicy = .default) -> OperationHandle<Op> {
        let handle = handle(for: operation, fetchPolicy: fetchPolicy)
        // Only a fetch the preload made can serve the first attach.
        handle.preloaded = handle.isFetching
        if handle.retainCount == 0 { evict(store.park(handle.key)) }
        return handle
    }

    /// Settles again the phases a commit's field errors or nulls can change:
    /// those of retained `@throwOnFieldError` and bubbling operations.
    func reevaluate() {
        for handle in handles.values where handle.retainCount > 0 {
            handle.reevaluate()
        }
    }

    /// Marks every handle's data stale. Retained handles whose holders allow
    /// the network refetch at once; the data stays visible until the response
    /// commits.
    public func invalidate() {
        guard !ended else { return }
        store.invalidate()
        for handle in handles.values where handle.retainCount > 0 {
            handle.refetchIfStale()
        }
    }

    /// Ends the session, once and for good: cancels every fetch and stream
    /// the environment started, drops the roots, clears every record and
    /// closes the image, giving its file back. A handle still held reads
    /// `.failed(EnvironmentError.gone)` and tells its observers; a lens still
    /// held finds its records cleared; every later call on the environment
    /// fails with the same error, and a response that lands later reaches
    /// neither memory nor the image. The order of a sign-out is the app's:
    /// end the environment, remove the image, forget the credential last.
    public func end() async {
        guard !ended else { return }
        ended = true
        for handle in handles.values { handle.end() }
        handles.removeAll()
        store.end()
        await store.persistence?.close()
        // After the writer, which named the rows it wrote by them: the
        // process keeps no text the session rendered.
        store.keys.clear()
    }

    /// Refetches the retained operations that are stale or whose last fetch
    /// failed, where a holder allows the network: for an app's return to the
    /// foreground, or a connection regained. Marks nothing; `invalidate()`
    /// does.
    public func revalidate() {
        guard !ended else { return }
        for handle in handles.values where handle.retainCount > 0 {
            handle.revalidate()
        }
    }

    /// The heal: a read under `root` found data missing. The store marks the
    /// root stale, and its handle refetches if a holder allows the network,
    /// once per fetch of the root; a field still missing after the heal's own
    /// refetch is reported as unexpected and healed no further. A lens with
    /// no root, made by hand, is reported and not healed.
    func heal(_ root: Store.Root?, _ record: Record, _ slot: Slot) {
        guard let root, !ended else { return }
        guard store.heal(root) else {
            store.reportUnexpected?(record, slot, .missing)
            return
        }
        handles[root.key]?.fetchForHeal()
    }

    private func request<Op: Operation>(_ operation: Op.Type, variables: Variables) -> Request {
        Request(
            operationName: Op.name,
            kind: Op.kind,
            document: Op.document,
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
        guard !ended else { throw EnvironmentError.gone }
        let committed = try await fetch(Op.self, variables: operation.variables, resolved: Op.plan.resolve(operation.variables, in: store.keys), firstPart: firstPart.map { firstPart in { _ in firstPart() } })
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
    /// `dating` is the root of the operation the payload answers, which the
    /// commit stamps with the time, so that every server write dates its
    /// operation, whoever asked for it.
    func commit(_ payload: Data, plan: ResolvedSelection, root: Store.Root, replacing layer: UUID? = nil, checkingCancellation: Bool = true, complete: Bool = true) async throws -> Committed {
        let changes = try await Ingest.normalized(payload, plan: plan, rootKey: root.record.key, complete: complete)
        if checkingCancellation { try Task.checkCancellation() }
        return commit(changes, replacing: layer, dating: root)
    }

    /// The door's lower half: a change set committed as a server batch, and
    /// the root dated when the change set completes its operation's response.
    /// The parts of a deferred stream after the first arrive here as the
    /// change sets the delivery assembled, and the last of them dates.
    func commit(_ changes: ChangeSet, replacing layer: UUID? = nil, dating root: Store.Root? = nil) -> Committed {
        // The terminal check: a response that lands after the end, which
        // cancellation could not reach, a fetch awaited in a task of the
        // app's own or a mutation the server applied, reaches neither
        // memory nor the image.
        guard !ended else { return Committed() }
        store.commit(changes, replacingOptimistic: layer)
        if let root { evict(store.date(root)) }
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
        guard !ended else { throw EnvironmentError.gone }
        let root = store.root(Op.name + operation.variables.json, resolved: Op.plan.resolve(operation.variables, in: store.keys), record: rootRecord(of: Op.self))
        let committed = try await commit(payload, plan: root.resolved, root: root, checkingCancellation: false, complete: false)
        if Op.throwsOnFieldError, !committed.uncaught.isEmpty { throw FieldErrors(committed.uncaught) }
    }

    /// The record an operation's payload hangs off, by the operation's kind.
    private func rootRecord<Op: Operation>(of operation: Op.Type) -> Record {
        if operation is any Mutation.Type { return store.mutationRoot }
        if operation is any Subscription.Type { return store.subscriptionRoot }
        return store.root
    }

    /// Fetches an operation by its type and variables and commits the response.
    /// Refetches and pagination run this way: no handle comes of it, and the
    /// operation's root, dated by the commit, waits in the release buffer if
    /// nothing retains it. Returns the field errors no `@catch` handled.
    @discardableResult
    public func fetch<Op: Query>(_ operation: Op.Type, variables: Variables, firstPart: (() -> Void)? = nil) async throws -> [FieldError] {
        guard !ended else { throw EnvironmentError.gone }
        return try await fetch(operation, variables: variables, resolved: Op.plan.resolve(variables, in: store.keys), firstPart: firstPart.map { firstPart in { _ in firstPart() } }).uncaught
    }

    private func fetch<Op: Query>(_ operation: Op.Type, variables: Variables, resolved: ResolvedSelection, firstPart: ((Committed) -> Void)?) async throws -> Committed {
        let request = request(Op.self, variables: variables)
        // The operation's root: a handle's, or one made here, which waits in
        // the release buffer once dated if nothing retains it.
        let root = store.root(Op.name + variables.json, resolved: resolved, record: store.root)
        if !Op.hasDeferred {
            // A fetch superseded while its response was on the way or being
            // read must not land after the one that replaced it.
            return try await commit(try await transport.payload(request), plan: resolved, root: root)
        }
        var committed = Committed()
        var delivery = Delivery(store: store, resolved: resolved)
        var first = true
        for try await part in transport.send(request) {
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
        // A deferred response is fetched, and fresh, once its stream completes.
        evict(store.date(root))
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
        guard !ended else { throw EnvironmentError.gone }
        let resolved = Op.plan.resolve(operation.variables, in: store.keys)
        let root = store.root(Op.name + operation.variables.json, resolved: resolved, record: store.mutationRoot)
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
            let data = try await Task { try await transport.payload(request) }.value
            uncaught = try await commit(data, plan: resolved, root: root, replacing: layer, checkingCancellation: false).uncaught
        } catch {
            if let layer { store.revertOptimistic(layer) }
            throw error
        }
        store.keepCompleted(root)
        if Op.throwsOnFieldError, !uncaught.isEmpty { throw FieldErrors(uncaught) }
        return Op.Data(anchor: Anchor(record: store.mutationRoot, owner: Owner(variables: operation.variables, store: store, environment: self)))
    }

    /// The events of a subscription, as the transport delivers them.
    func subscribe<Op: Subscription>(_ operation: Op) -> AsyncThrowingStream<Data, any Error> {
        guard let subscriptions, !ended else {
            let failure: EnvironmentError = ended ? .gone : .noSubscriptionTransport
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: failure)
            }
        }
        return subscriptions.send(request(Op.self, variables: operation.variables))
    }

    // MARK: Lifetime

    /// A handle retained: it is among the environment's again if its root
    /// had left.
    func didRetain(_ handle: any AnyOperationHandle) {
        if handles[handle.key] == nil { handles[handle.key] = handle }
    }

    /// A subscription released to no holder: its stream closed and its root
    /// left the store at once.
    func didEnd(_ handle: any AnyOperationHandle) {
        handles.removeValue(forKey: handle.key)
    }

    /// Drops the handles of roots the store pushed out, with the fetches they
    /// had in flight.
    func evict(_ keys: [String]) {
        for key in keys {
            handles[key]?.cancel()
            handles.removeValue(forKey: key)
        }
    }

    /// A placeholder for views outside any `.environment(\.baton, …)`.
    package static let unconfigured = Environment(transport: UnconfiguredTransport())

    /// The environment a view sees: the injected one, or the placeholder.
    package static func resolve(_ injected: Environment?) -> Environment { injected ?? unconfigured }
}

struct UnconfiguredTransport: Transport {
    func send(_ request: Request) -> AsyncThrowingStream<Data, any Error> {
        Self.once { throw EnvironmentError.notInjected }
    }
}
