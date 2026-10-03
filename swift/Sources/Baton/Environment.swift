import SwiftUI

/// Store plus transport plus configuration, in Relay's sense. One per backend,
/// injected through SwiftUI's environment as `\.baton`. It also owns the
/// operations' lifetime: retained handles and the release buffer are the roots
/// that keep records alive.
@MainActor
public final class Environment {
    public let store: Store
    public let transport: any Transport

    /// How many released operations keep their data alive, oldest out first.
    public var releaseBufferSize = 10
    /// How long a fetched response stays fresh; `nil` means forever.
    public var queryCacheExpiration: Duration?

    private var handles: [AnyHashable: any AnyOperationHandle] = [:]
    private var releaseBuffer: [AnyHashable] = []
    private var collectionScheduled = false
    /// How many collections have run; for tests and benchmarks.
    public private(set) var collections = 0

    public init(transport: any Transport, store: Store = Store()) {
        self.store = store
        self.transport = transport
    }

    public convenience init(url: URL, headers: [String: String] = [:]) {
        self.init(transport: URLSessionTransport(url: url, headers: headers))
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

    /// Starts fetching before any view asks; the handle waits in the release
    /// buffer for a view to attach.
    @discardableResult
    public func preload<Op: Operation>(_ operation: Op, fetchPolicy: FetchPolicy = .storeAndNetwork) -> OperationHandle<Op> {
        let handle = handle(for: operation, fetchPolicy: fetchPolicy)
        if handle.retainCount == 0 { park(handle.key) }
        return handle
    }

    /// Marks every handle's data stale. Retained handles refetch at once; the
    /// data stays visible until the response commits.
    public func invalidate() {
        store.invalidate()
        for handle in handles.values where handle.retainCount > 0 {
            handle.refetchIfStale()
        }
    }

    /// Fetches an operation and commits the response; the handle, if any, follows.
    public func fetch<Op: Operation>(_ operation: Op) async throws {
        let request = Request(
            operationName: Op.name,
            text: Op.text,
            persistedID: Op.persistedID,
            variables: operation.variables
        )
        let data = try await transport.execute(request)
        let resolved = Op.plan.resolve(operation.variables)
        let changes = try await Task.detached(priority: .userInitiated) {
            try Ingest.normalize(data, plan: resolved)
        }.value
        store.commit(changes)
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
