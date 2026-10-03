import Observation
import SwiftUI

public enum OperationKind: Sendable {
    case query, mutation, subscription
}

/// What the store may answer and when the network is asked. Relay's four.
public enum FetchPolicy: Sendable {
    /// Render from the store when it has everything and nothing is stale;
    /// otherwise fetch.
    case storeOrNetwork
    /// Render what the store has at once, and always fetch.
    case storeAndNetwork
    /// Show loading until this handle's own response arrives.
    case networkOnly
    /// Never fetch; fail when the store cannot answer.
    case storeOnly
}

/// An operation value: the variables of one operation, `Hashable` by them.
/// The compiler generates one struct per operation; inside a view the value
/// resolves to a handle through `@Query`.
public protocol Operation: Hashable, Sendable {
    associatedtype Data: Lens
    static var name: String { get }
    static var kind: OperationKind { get }
    static var text: String { get }
    static var persistedID: String { get }
    static var plan: Plan { get }
    var variables: Variables { get }
    var resolution: OperationHandle<Self>? { get set }
}

/// The state of a resolved operation. Always synchronously readable.
public enum Phase<Data> {
    case loading
    case ready(Data)
    case failed(any Error)
}

/// A `storeOnly` operation whose data the store does not have.
public struct MissingDataError: Error, CustomStringConvertible, Sendable {
    public let operationName: String
    public var description: String { "\(operationName): the store does not have this data and the policy forbids fetching" }
}

extension Operation {
    /// Loading until resolved inside a view.
    @MainActor public var phase: Phase<Data> { resolution?.phase ?? .loading }

    /// Whether a fetch is running while earlier data stays visible.
    @MainActor public var isRefreshing: Bool { resolution?.isRefreshing ?? false }

    /// Whether the data predates an invalidation or the cache expiration.
    @MainActor public var isStale: Bool { resolution?.isStale ?? false }

    /// Fetches again and commits; the data stays visible meanwhile.
    @MainActor public func refetch() async { await resolution?.refetch() }

    /// After a failure, fetches again.
    @MainActor public func retry() { resolution?.retry() }
}

/// Type-erased view of a handle, for the environment's bookkeeping.
@MainActor
protocol AnyOperationHandle: AnyObject {
    var retainCount: Int { get }
    var key: AnyHashable { get }
    func mark(into reachable: inout Set<ObjectIdentifier>)
    func refetchIfStale()
    func cancel()
}

/// The live side of an operation value: its phase, its fetch, its data, and
/// its place among the store's roots. Created by the environment, shared by
/// equal operation values.
@MainActor
@Observable
public final class OperationHandle<Op: Operation>: AnyOperationHandle {
    public let operation: Op
    public private(set) var phase: Phase<Op.Data> = .loading
    public private(set) var isRefreshing = false
    /// When this handle last committed a response.
    public private(set) var fetchTime: ContinuousClock.Instant?
    @ObservationIgnored private(set) var fetchEpoch = 0
    @ObservationIgnored private unowned let environment: Environment
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let resolved: ResolvedSelection
    @ObservationIgnored public internal(set) var retainCount = 0

    init(operation: Op, environment: Environment) {
        self.operation = operation
        self.environment = environment
        resolved = Op.plan.resolve(operation.variables)
    }

    var key: AnyHashable { AnyHashable(operation) }

    private var data: Op.Data {
        Op.Data(anchor: Anchor(record: environment.store.root, variables: operation.variables, store: environment.store))
    }

    /// Whether the store holds every field the operation selects.
    public var isComplete: Bool { environment.store.check(resolved) }

    /// Whether the data predates `Environment.invalidate()` or the expiration.
    public var isStale: Bool {
        guard case .ready = phase else { return false }
        if fetchEpoch < environment.store.invalidationEpoch { return true }
        if let expiration = environment.queryCacheExpiration, let fetchTime, fetchTime + expiration < .now { return true }
        return false
    }

    /// Applies a policy on attach: renders what the store allows, fetches
    /// when the policy asks for it.
    func apply(_ policy: FetchPolicy) {
        let complete = isComplete
        if complete, policy != .networkOnly, case .loading = phase {
            phase = .ready(data)
        }
        switch policy {
        case .storeOnly:
            if !complete, case .loading = phase {
                phase = .failed(MissingDataError(operationName: Op.name))
            }
        case .storeOrNetwork:
            if !complete || isStale { fetch() }
        case .storeAndNetwork:
            fetch()
        case .networkOnly:
            if fetchTime == nil { phase = .loading }
            fetch()
        }
    }

    /// Starts a fetch unless one is in flight.
    func fetch() {
        guard task == nil else { return }
        start()
    }

    private func start() {
        task?.cancel()
        if case .ready = phase { isRefreshing = true }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                isRefreshing = false
            }
            do {
                try await environment.fetch(operation)
                guard !Task.isCancelled else { return }
                fetchTime = .now
                fetchEpoch = environment.store.invalidationEpoch
                phase = .ready(data)
            } catch is CancellationError {
                return
            } catch {
                if case .ready = phase {
                    // Earlier data stays visible; the failure shows through the end of isRefreshing.
                } else {
                    phase = .failed(error)
                }
            }
        }
    }

    /// Fetches again and waits for the result; the data stays visible meanwhile.
    public func refetch() async {
        start()
        await task?.value
    }

    /// Waits for an in-flight fetch, if any.
    public func settle() async {
        await task?.value
    }

    public func retry() {
        if case .failed = phase { phase = .loading }
        start()
    }

    /// Keeps the operation's records alive. `@Query` does this for a view's
    /// lifetime; other owners (view models, UIKit controllers) call it directly
    /// and must balance it with `release()`.
    public func retain() {
        retainCount += 1
        environment.didRetain(self)
    }

    /// Balances `retain()`. At zero the handle enters the release buffer.
    public func release() {
        retainCount -= 1
        if retainCount <= 0 {
            retainCount = 0
            environment.didRelease(self)
        }
    }

    func refetchIfStale() {
        if isStale { fetch() }
    }

    func mark(into reachable: inout Set<ObjectIdentifier>) {
        environment.store.mark(resolved, into: &reachable)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// What a `@Query` property expands to: owns the handle for the view's
/// lifetime, retains it while the view lives, and hands out the operation
/// value with the handle attached.
@MainActor
public struct OperationStorage<Op: Operation>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var box = Box()
    private let value: Op
    private let fetchPolicy: FetchPolicy

    final class Box: @unchecked Sendable {
        nonisolated(unsafe) var handle: OperationHandle<Op>?

        deinit {
            guard let handle else { return }
            Task { @MainActor in handle.release() }
        }
    }

    public init(_ value: Op, fetchPolicy: FetchPolicy = .storeAndNetwork) {
        self.value = value
        self.fetchPolicy = fetchPolicy
    }

    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            if box.handle?.operation != value {
                box.handle?.release()
                let handle = Environment.resolve(environment).handle(for: value, fetchPolicy: fetchPolicy)
                handle.retain()
                box.handle = handle
            }
        }
    }

    /// The value, resolved. Outside a view it is unresolved and reads as loading.
    public var resolved: Op {
        var resolved = value
        resolved.resolution = box.handle
        return resolved
    }
}
