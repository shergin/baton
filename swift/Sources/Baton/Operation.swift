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
    /// `@throwOnFieldError`: an uncaught field error fails the operation.
    static var throwsOnFieldError: Bool { get }
    /// Whether a `@required` field at the root can null the whole result.
    static var bubbles: Bool { get }
    /// Whether the response may arrive in parts (`@defer`).
    static var hasDeferred: Bool { get }
    var variables: Variables { get }
    var resolution: OperationHandle<Self>? { get set }
}

extension Operation {
    public static var throwsOnFieldError: Bool { false }
    public static var bubbles: Bool { false }
    public static var hasDeferred: Bool { false }
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

    /// Fetches again and commits; the data stays visible meanwhile, and a
    /// failure is thrown here rather than shown in place of it.
    @MainActor public func refetch() async throws { try await resolution?.refetch() }

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
    /// Settles the phase again after a commit changed a field error or a
    /// null, for policies that read them.
    func reevaluate()
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
    /// The environment that made the handle. A view may release its handle
    /// after the environment is gone, which then does nothing.
    @ObservationIgnored private(set) weak var environment: Environment?
    @ObservationIgnored private let store: Store
    /// The fetch in flight; its value is the failure it ended with.
    @ObservationIgnored private var task: Task<(any Error)?, Never>?
    @ObservationIgnored let resolved: ResolvedSelection
    /// The scope every lens of the handle reads in.
    @ObservationIgnored private let owner: Owner
    @ObservationIgnored public internal(set) var retainCount = 0
    /// Set by a `preload` that fetched: the first attach finds the fetch
    /// made, or on the way.
    @ObservationIgnored var preloaded = false
    /// The field errors of the last fetch that no field in the store holds,
    /// which `@throwOnFieldError` counts until the next fetch.
    @ObservationIgnored private var unplaced: [FieldError] = []

    init(operation: Op, environment: Environment) {
        self.operation = operation
        self.environment = environment
        store = environment.store
        resolved = Op.plan.resolve(operation.variables)
        owner = Owner(variables: operation.variables, store: environment.store)
    }

    var key: AnyHashable { AnyHashable(operation) }

    /// Moves to the next phase. Ready after ready is no change: both carry a
    /// lens over the same root, so a fetch that changed nothing re-runs no
    /// body that reads the phase. Nor is a failure on the same field errors,
    /// or the same `@required` path, after another.
    private func settle(_ next: Phase<Op.Data>) {
        switch (phase, next) {
        case (.ready, .ready):
            return
        case let (.failed(old as FieldErrors), .failed(new as FieldErrors)) where old.errors == new.errors:
            return
        case let (.failed(old as RequiredFieldError), .failed(new as RequiredFieldError)) where old.path == new.path:
            return
        default:
            phase = next
        }
    }

    /// Whether a fetch is in flight.
    var isFetching: Bool { task != nil }

    private var anchor: Anchor {
        Anchor(record: store.root, owner: owner)
    }

    private var data: Op.Data { Op.Data(anchor: anchor) }

    /// The phase the store's data deserves: ready, unless the operation's
    /// policies say otherwise. `@throwOnFieldError` fails on an uncaught field
    /// error in the operation's own selection, as Relay's reader of the
    /// operation does (a spread's fragment weighs its own), or on one the
    /// last response carried that no field holds; a root whose `@required`
    /// fields bubble fails, because there is no null data. The fetch and
    /// every later commit settle the phase by this one reading.
    private func evaluate() -> Phase<Op.Data> {
        if Op.throwsOnFieldError {
            let errors = unplaced + Op.Data.fieldErrors(anchor)
            if !errors.isEmpty { return .failed(FieldErrors(errors)) }
        }
        if Op.bubbles, !Op.Data.satisfied(anchor) {
            return .failed(RequiredFieldError(path: Op.name))
        }
        return .ready(data)
    }

    /// Whether the store holds every field the operation selects.
    public var isComplete: Bool { store.check(resolved) }

    /// Whether the data predates `Environment.invalidate()` or the expiration.
    public var isStale: Bool {
        guard case .ready = phase else { return false }
        if fetchEpoch < store.invalidationEpoch { return true }
        if let expiration = environment?.queryCacheExpiration, let fetchTime, fetchTime + expiration < .now { return true }
        return false
    }

    /// The operation as the image names it: its name and its variables.
    private var imageKey: String { Op.name + operation.variables.json }

    /// Notes a response that just committed: the handle's own clock, and the
    /// image's, which a later launch reads the age from.
    private func didFetch() {
        fetchTime = .now
        fetchEpoch = store.invalidationEpoch
        store.persistence?.fetched(imageKey)
    }

    /// Gives data this handle did not fetch the age the image knows: the time
    /// since an earlier launch fetched it. Data that had to be read from the
    /// image and has no such time is stale.
    private func takeAge(hydrated: Bool) {
        guard fetchTime == nil, let persistence = store.persistence else { return }
        if let age = persistence.age(of: imageKey) {
            fetchTime = .now - .seconds(age)
            fetchEpoch = store.invalidationEpoch
        } else if hydrated {
            fetchEpoch = store.invalidationEpoch - 1
        }
    }

    /// Applies a policy on attach: renders what the store allows, fetches
    /// when the policy asks for it.
    func apply(_ policy: FetchPolicy) {
        // A preload's fetch is the first attach's: in flight, or done with
        // data that is still fresh, it is not made again.
        if preloaded {
            preloaded = false
            if task != nil { return }
            if case .ready = phase, !isStale { return }
        }
        if policy == .networkOnly {
            // What the store holds is not asked; a handle no one shows yet
            // waits for its own response.
            if retainCount == 0 { phase = .loading }
            fetch()
            return
        }
        let hydrated = store.hydratedRecords
        let complete = isComplete
        if complete { takeAge(hydrated: store.hydratedRecords != hydrated) }
        if complete {
            switch phase {
            case .loading:
                phase = evaluate()
            // A parked handle saw no commit: what it failed on may be gone.
            case .failed(let error) where error is FieldErrors || error is RequiredFieldError:
                settle(evaluate())
            default:
                break
            }
        }
        switch policy {
        case .storeOnly:
            if !complete, case .loading = phase {
                phase = .failed(MissingDataError(operationName: Op.name))
            }
        case .storeOrNetwork:
            if !complete || isStale { fetch() }
        case .storeAndNetwork, .networkOnly:
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
        guard environment != nil else {
            // Nothing can fetch for a handle whose environment is gone: it
            // keeps the data it shows and says why it cannot load more.
            task = nil
            isRefreshing = false
            if case .loading = phase {
                phase = .failed(TransportError(statusCode: 0, body: "the handle's environment is gone, so it cannot fetch"))
            }
            return
        }
        if case .ready = phase { isRefreshing = true }
        task = Task { [weak self] in
            guard let self, let environment else { return nil }
            var failure: (any Error)?
            do {
                let fetched = try await environment.fetch(operation, resolved: resolved) { [weak self] in
                    // A deferred response renders its first part at once; it
                    // is fetched, and fresh, once the stream completes.
                    guard let self, !Task.isCancelled else { return }
                    settle(evaluate())
                }
                if !Task.isCancelled { unplaced = fetched.unplaced }
            } catch {
                failure = error
            }
            // A cancelled fetch was superseded or evicted. The handle's state
            // belongs to whoever cancelled it, however the fetch ended.
            guard !Task.isCancelled else { return nil }
            task = nil
            isRefreshing = false
            switch failure {
            case nil:
                didFetch()
                settle(evaluate())
                // A response whose field errors fail the operation fails its
                // refetch the same way.
                if case .failed(let error) = phase { return error }
            case is CancellationError:
                return nil
            case let error?:
                // Earlier data stays visible; `refetch()` throws the failure.
                if case .ready = phase { return error }
                phase = .failed(error)
            }
            return failure
        }
    }

    /// Fetches again and waits for the result; the data stays visible
    /// meanwhile, and a failure is thrown rather than shown in its place. A
    /// refetch that a later fetch superseded returns without one.
    public func refetch() async throws {
        start()
        if let failure = await task?.value { throw failure }
    }

    /// Waits for an in-flight fetch, if any.
    public func settle() async {
        _ = await task?.value
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
        environment?.didRetain(self)
    }

    /// Balances `retain()`. At zero the handle enters the release buffer.
    public func release() {
        retainCount -= 1
        if retainCount <= 0 {
            retainCount = 0
            environment?.didRelease(self)
        }
    }

    func refetchIfStale() {
        if isStale { fetch() }
    }

    func reevaluate() {
        guard Op.throwsOnFieldError || Op.bubbles else { return }
        switch phase {
        case .loading:
            return
        case .failed(let error) where !(error is FieldErrors || error is RequiredFieldError):
            return
        default:
            settle(evaluate())
        }
    }

    func mark(into reachable: inout Set<ObjectIdentifier>) {
        store.mark(resolved, into: &reachable)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRefreshing = false
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

    /// Resolves the value to a handle when the value or the environment the
    /// view sees changed: a handle belongs to the environment that made it.
    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            let current = Environment.resolve(environment)
            if box.handle?.operation != value || box.handle?.environment !== current {
                box.handle?.release()
                let handle = current.handle(for: value, fetchPolicy: fetchPolicy)
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

/// The in-flight state behind a mutation action, observable by the view.
@MainActor
@Observable
public final class MutationState {
    public internal(set) var inFlight = 0
    public init() {}
}

/// A mutation as a callable value, after SwiftUI's `dismiss` and `openURL`.
/// The compiler generates `callAsFunction` with one labelled parameter per
/// variable plus `optimistic:`; this is what it calls.
public struct MutationAction<Op: Operation>: Sendable {
    let environment: Environment?
    let state: MutationState

    /// Whether a commit is running.
    @MainActor public var isInFlight: Bool { state.inFlight > 0 }

    /// Commits the mutation. An optimistic response shows at once as a layer
    /// that rebases under every commit until the server answers; on failure
    /// it is reverted and the error rethrown.
    @MainActor
    public func commit(_ operation: Op, optimistic: Variable? = nil) async throws -> Op.Data {
        let environment = Environment.resolve(environment)
        state.inFlight += 1
        defer { state.inFlight -= 1 }
        return try await environment.mutate(operation, optimistic: optimistic)
    }
}

/// What a `@Mutation` property expands to: the environment and the in-flight
/// state, handed out as an action.
@MainActor
public struct MutationStorage<Op: Operation>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var state = MutationState()

    public init() {}

    public var action: MutationAction<Op> {
        MutationAction(environment: environment, state: state)
    }
}

// MARK: Subscriptions

/// The live side of a subscription value: the stream it holds open, how many
/// events arrived, the latest event's data, and the error that ended it.
/// Each event is normalized with the operation's plan at the subscription root
/// and committed, so its entities merge and its edge directives apply.
@MainActor
@Observable
public final class SubscriptionHandle<Op: Operation>: AnyOperationHandle {
    public let operation: Op
    /// How many events have been committed.
    public private(set) var events = 0
    /// The latest event, as a lens over the subscription root.
    public private(set) var latest: Op.Data?
    /// The error of the last event, cleared by the next good one, or the
    /// error that ended the stream.
    public private(set) var error: (any Error)?
    /// Whether the stream is open.
    public private(set) var isActive = false
    /// The environment that made the handle; releasing the handle after it
    /// is gone does nothing.
    @ObservationIgnored private(set) weak var environment: Environment?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let resolved: ResolvedSelection
    /// The scope every event's lens reads in.
    @ObservationIgnored private let owner: Owner
    @ObservationIgnored public internal(set) var retainCount = 0

    init(operation: Op, environment: Environment) {
        self.operation = operation
        self.environment = environment
        store = environment.store
        resolved = Op.plan.resolve(operation.variables)
        owner = Owner(variables: operation.variables, store: environment.store)
    }

    var key: AnyHashable { AnyHashable(operation) }

    /// Opens the stream unless it is open, or its environment is gone.
    func start() {
        guard task == nil, environment != nil else { return }
        isActive = true
        error = nil
        task = Task { [weak self] in
            guard let self, let environment else { return }
            do {
                for try await payload in environment.subscribe(operation) {
                    guard !Task.isCancelled else { return }
                    do {
                        let changes = try await Ingest.normalized(payload, plan: resolved, rootKey: Store.subscriptionRootKey)
                        guard !Task.isCancelled else { return }
                        store.commit(changes)
                        events += 1
                        latest = Op.Data(anchor: Anchor(record: store.subscriptionRoot, owner: owner))
                        error = nil
                    } catch let failure as GraphQLErrors {
                        // An event with errors and no data is one bad event;
                        // the stream goes on.
                        error = failure
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error
            }
            // A stream a newer one replaced leaves the newer one's state be.
            guard !Task.isCancelled else { return }
            task = nil
            isActive = false
        }
    }

    /// Opens the stream again after it ended, by an error or the server's
    /// completion, while the handle is retained.
    public func retry() {
        guard retainCount > 0 else { return }
        cancel()
        start()
    }

    /// Keeps the stream open and the latest event's records alive.
    public func retain() {
        retainCount += 1
        environment?.didRetain(self)
        SubscriptionResolution.add(self)
        start()
    }

    /// Balances `retain()`. At zero the stream closes; nothing is buffered.
    public func release() {
        retainCount -= 1
        if retainCount <= 0 {
            retainCount = 0
            cancel()
            SubscriptionResolution.remove(self)
            environment?.didEnd(self)
        }
    }

    func refetchIfStale() {}

    func reevaluate() {}

    func mark(into reachable: inout Set<ObjectIdentifier>) {
        store.mark(resolved, from: store.subscriptionRoot, into: &reachable)
    }

    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
    }
}

/// A subscription value, resolved inside a view through `@Subscription`.
extension Operation {
    /// The live side, while a view or another owner retains its handle.
    @MainActor public var subscription: SubscriptionHandle<Self>? { SubscriptionResolution.handle(for: self) }
}

/// Where a subscription value finds its handle, so the value's accessors can
/// reach it without a second stored property. A handle is listed while it is
/// retained and dropped when its last owner releases it. The list is keyed by
/// the value alone: equal values in two environments share an entry, and the
/// handle retained last answers.
@MainActor
enum SubscriptionResolution {
    private static var handles: [AnyHashable: AnyObject] = [:]

    static func add<Op: Operation>(_ handle: SubscriptionHandle<Op>) {
        handles[AnyHashable(handle.operation)] = handle
    }

    /// Drops the handle's entry, unless another handle has taken it.
    static func remove<Op: Operation>(_ handle: SubscriptionHandle<Op>) {
        let key = AnyHashable(handle.operation)
        guard handles[key] === handle else { return }
        handles.removeValue(forKey: key)
    }

    static func handle<Op: Operation>(for operation: Op) -> SubscriptionHandle<Op>? {
        handles[AnyHashable(operation)] as? SubscriptionHandle<Op>
    }
}

/// What a `@Subscription` property expands to: subscribes while the view
/// lives, closes the stream when SwiftUI drops the view's state, and hands out
/// the operation value with the handle attached.
@MainActor
public struct SubscriptionStorage<Op: Operation>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var box = Box()
    private let value: Op

    final class Box: @unchecked Sendable {
        nonisolated(unsafe) var handle: SubscriptionHandle<Op>?

        deinit {
            guard let handle else { return }
            Task { @MainActor in handle.release() }
        }
    }

    public init(_ value: Op) {
        self.value = value
    }

    /// Resolves the value to a handle when the value or the environment the
    /// view sees changed.
    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            let current = Environment.resolve(environment)
            if box.handle?.operation != value || box.handle?.environment !== current {
                box.handle?.release()
                let handle = current.subscriptionHandle(for: value)
                handle.retain()
                box.handle = handle
            }
        }
    }

    /// The value; `subscription` reaches its live side while the storage
    /// retains the handle.
    public var resolved: Op { value }
}
