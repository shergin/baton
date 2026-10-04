import SwiftUI

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

    /// How many released operations keep their data alive, oldest out first.
    public var releaseBufferSize = 10
    /// How long a fetched response stays fresh; `nil` means forever.
    public var queryCacheExpiration: Duration?
    /// The `onError` behaviour asked of the server, when set.
    public var errorBehavior: ErrorBehavior?
    /// Called when a `@required(action: LOG)` field is null: the record and
    /// Relay's path. Debug builds print by default.
    public var requiredFieldMissing: ((Record, String) -> Void)?

    private var handles: [AnyHashable: any AnyOperationHandle] = [:]
    private var releaseBuffer: [AnyHashable] = []
    private var collectionScheduled = false
    /// How many collections have run; for tests and benchmarks.
    public private(set) var collections = 0

    public init(transport: any Transport, subscriptions: (any SubscriptionTransport)? = nil, store: Store = Store()) {
        self.store = store
        self.transport = transport
        self.subscriptions = subscriptions
        store.environment = self
        #if DEBUG
        requiredFieldMissing = { record, path in
            print("Baton: the @required field \(path) of \(record.key) is null; its lens reads as null")
        }
        #endif
    }

    /// An environment over HTTP. With `persistence`, the store keeps an image
    /// on disk and a launch renders from it before the network answers.
    public convenience init(url: URL, headers: [String: String] = [:], subscriptions: (any SubscriptionTransport)? = nil, persistence: Persistence? = nil) {
        self.init(transport: URLSessionTransport(url: url, headers: headers), subscriptions: subscriptions, store: Store(persistence: persistence))
    }

    /// The handle for an operation value, shared by every view that holds an
    /// equal value. The policy is applied on every attach.
    public func handle<Op: Operation>(for operation: Op, fetchPolicy: FetchPolicy = .storeAndNetwork) -> OperationHandle<Op> {
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
    public func subscriptionHandle<Op: Operation>(for operation: Op) -> SubscriptionHandle<Op> {
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
    public func preload<Op: Operation>(_ operation: Op, fetchPolicy: FetchPolicy = .storeAndNetwork) -> OperationHandle<Op> {
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
        store.persistence?.invalidate()
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
            errorBehavior: errorBehavior,
            incremental: Op.hasDeferred
        )
    }

    /// Fetches an operation and commits the response; the handle, if any,
    /// follows. `firstPart` runs after the first part of a deferred response
    /// commits, so a view renders before the rest arrives.
    public func fetch<Op: Operation>(_ operation: Op, firstPart: (() -> Void)? = nil) async throws {
        let fetched = try await fetch(Op.self, variables: operation.variables, resolved: Op.plan.resolve(operation.variables), firstPart: firstPart)
        if Op.throwsOnFieldError, !fetched.uncaught.isEmpty { throw FieldErrors(fetched.uncaught) }
    }

    /// What a fetch committed besides its records: the field errors no
    /// `@catch` handled, and those no field in the store holds.
    struct Fetched {
        var uncaught: [FieldError] = []
        var unplaced: [FieldError] = []

        mutating func add(_ changes: ChangeSet) {
            uncaught.append(contentsOf: changes.uncaughtFieldErrors)
            unplaced.append(contentsOf: changes.unplacedErrors)
        }
    }

    /// Fetches with a plan already resolved, as a handle holds it. The field
    /// errors are the handle's to weigh, so none is thrown.
    func fetch<Op: Operation>(_ operation: Op, resolved: ResolvedSelection, firstPart: (() -> Void)? = nil) async throws -> Fetched {
        try await fetch(Op.self, variables: operation.variables, resolved: resolved, firstPart: firstPart)
    }

    /// Fetches an operation by its type and variables and commits the response.
    /// No handle and no root come of it: refetches and pagination run this way,
    /// and the records they fill stay alive through whatever reaches them.
    /// Returns the field errors no `@catch` handled.
    @discardableResult
    public func fetch<Op: Operation>(_ operation: Op.Type, variables: Variables, firstPart: (() -> Void)? = nil) async throws -> [FieldError] {
        try await fetch(operation, variables: variables, resolved: Op.plan.resolve(variables), firstPart: firstPart).uncaught
    }

    private func fetch<Op: Operation>(_ operation: Op.Type, variables: Variables, resolved: ResolvedSelection, firstPart: (() -> Void)?) async throws -> Fetched {
        let request = request(Op.self, variables: variables)
        if !Op.hasDeferred {
            let data = try await transport.execute(request)
            let changes = try await Ingest.normalized(data, plan: resolved)
            // A fetch superseded while its response was on the way or being
            // read must not land after the one that replaced it.
            try Task.checkCancellation()
            store.commit(changes)
            var fetched = Fetched()
            fetched.add(changes)
            return fetched
        }
        var fetched = Fetched()
        var first = true
        var pending: [String: Ingest.IncrementalPart.Pending] = [:]
        for try await part in transport.stream(request) {
            if first {
                first = false
                let changes = try await Ingest.normalized(part, plan: resolved)
                try Task.checkCancellation()
                store.commit(changes)
                fetched.add(changes)
                // The 2024 format announces the parts to come in the first one.
                for announced in changes.pending { pending[announced.id] = announced }
                firstPart?()
                if !changes.hasNext { break }
                continue
            }
            let incremental = try await Ingest.incrementalPart(part)
            for announced in incremental.pending { pending[announced.id] = announced }
            // Where each object goes is read from the store, here; the
            // objects are normalized off the main actor in one call.
            var objects: [Ingest.ObjectPart] = []
            for item in incremental.items {
                let base = item.path ?? item.id.flatMap { pending[$0]?.path }
                let label = item.label ?? item.id.flatMap { pending[$0]?.label }
                guard let base, let label else { continue }
                let path = base + (item.subPath ?? [])
                guard let (record, selection) = store.walk(path, resolved) else { continue }
                // Below the announced path the item carries the rest of an
                // object the part selects, by the object's own selection.
                let plan = item.subPath?.isEmpty == false ? selection : selection.deferred(label)
                guard let plan else { continue }
                objects.append(Ingest.ObjectPart(data: item.data, plan: plan, key: record.key, type: record.type, entity: record.isEntity, path: path, errors: item.errors))
            }
            var changes = try await Ingest.normalized(objects)
            for completion in incremental.completed where !completion.errors.isEmpty {
                guard let announced = pending[completion.id], let label = announced.label,
                      let (record, selection) = store.walk(announced.path, resolved),
                      let deferred = selection.deferred(label)
                else { continue }
                changes.append(Ingest.failed(deferred, key: record.key, type: record.type, entity: record.isEntity, at: announced.path, errors: completion.errors))
            }
            try Task.checkCancellation()
            for change in changes {
                store.commit(change)
                fetched.add(change)
            }
            if !incremental.hasNext { break }
        }
        return fetched
    }

    /// Fetches a page of a connection: the loading flag on the connection
    /// record is set for the duration, and the commit merges the page.
    func paginate<Op: Operation>(_ operation: Op.Type, variables: Variables, connection: Record, loading: Slot) async throws {
        connection.write(loading, .bool(true))
        defer { connection.write(loading, .bool(false)) }
        _ = try await fetch(operation, variables: variables)
    }

    /// Commits a mutation. The optimistic response, if any, is ingested with the
    /// mutation's own plan and applied as a layer first; the server's payload
    /// then replaces it in one batch, or the layer is reverted on failure.
    public func mutate<Op: Operation>(_ operation: Op, optimistic: Variable? = nil) async throws -> Op.Data {
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
            let changes = try await Ingest.normalized(data, plan: resolved, rootKey: Store.mutationRootKey)
            if let layer {
                store.commit(changes, replacingOptimistic: layer)
            } else {
                store.commit(changes)
            }
            uncaught = changes.uncaughtFieldErrors
        } catch {
            if let layer { store.revertOptimistic(layer) }
            throw error
        }
        if Op.throwsOnFieldError, !uncaught.isEmpty { throw FieldErrors(uncaught) }
        return Op.Data(anchor: Anchor(record: store.mutationRoot, variables: operation.variables, store: store))
    }

    /// The events of a subscription, as the transport delivers them.
    func subscribe<Op: Operation>(_ operation: Op) -> AsyncThrowingStream<Data, any Error> {
        guard let subscriptions else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TransportError(statusCode: 0, body: "no subscription transport: pass `subscriptions:` to the environment"))
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

    /// Handles that are roots for collection: retained or buffered.
    public var rootCount: Int { handles.count }

    private func scheduleCollection() {
        guard !collectionScheduled else { return }
        collectionScheduled = true
        Task { @MainActor in
            self.collectionScheduled = false
            self.collect()
        }
    }

    /// Removes every record no root reaches. Returns how many were removed.
    @discardableResult
    public func collect() -> Int {
        var reachable = Set<ObjectIdentifier>()
        reachable.reserveCapacity(store.count)
        for handle in handles.values {
            handle.mark(into: &reachable)
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
    public static let unconfigured = Environment(transport: UnconfiguredTransport())

    /// The environment a view sees: the injected one, or the placeholder.
    public static func resolve(_ injected: Environment?) -> Environment { injected ?? unconfigured }
}

struct UnconfiguredTransport: Transport {
    func execute(_ request: Request) async throws -> Data {
        throw TransportError(statusCode: 0, body: "no Baton environment: set `.environment(\\.baton, environment)` on an ancestor view")
    }
}

extension EnvironmentValues {
    /// The Baton environment for this view tree. Set it on an ancestor:
    /// `.environment(\.baton, environment)`.
    @Entry public var baton: Baton.Environment? = nil
}
