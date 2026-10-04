import Observation
import SwiftUI

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

    /// The policy an operation runs under unless it names one: the store
    /// answers when it can, and the network when it cannot or the data is
    /// stale, as Relay's queries do by default.
    public static let `default`: FetchPolicy = .storeOrNetwork
}

/// An operation value: the variables of one operation, `Hashable` by them.
/// The compiler generates one struct per operation, conforming to the
/// protocol of its kind: `Query`, `Mutation` or `Subscription`.
public protocol Operation: Hashable, Sendable {
    associatedtype Data: Lens
    static var name: String { get }
    static var text: String { get }
    static var persistedID: String { get }
    static var plan: Plan { get }
    /// `@throwOnFieldError`: an uncaught field error fails the operation.
    static var throwsOnFieldError: Bool { get }
    /// Whether a `@required` field at the root can null the whole result.
    static var bubbles: Bool { get }
    /// Whether the response may arrive in parts (`@defer`).
    static var hasDeferred: Bool { get }
    /// The `onError` value `baton.json` names, sent with every request.
    static var errorBehavior: ErrorBehavior? { get }
    var variables: Variables { get }
}

/// A query value: inside a view it resolves to a handle through `@Query`,
/// and reads its phase and data through it.
public protocol Query: Operation {
    var resolution: OperationHandle<Self>? { get set }
}

/// A mutation value: called as an action through `@Mutation`, or committed
/// with `Environment.mutate`.
public protocol Mutation: Operation {}

/// A subscription value: inside a view it resolves to a handle through
/// `@Subscription`, which holds the stream of events open.
public protocol Subscription: Operation {
    var resolution: SubscriptionHandle<Self>? { get set }
}

extension Operation {
    public static var throwsOnFieldError: Bool { false }
    public static var bubbles: Bool { false }
    public static var hasDeferred: Bool { false }
    public static var errorBehavior: ErrorBehavior? { nil }
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

extension Query {
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
    func release()
    func mark(into reachable: inout Set<ObjectIdentifier>)
    func refetchIfStale()
    /// Settles the phase again after a commit changed a field error or a
    /// null, for policies that read them.
    func reevaluate()
    func cancel()
}

/// A mutation that committed, kept by the environment as a root, so the data
/// `mutate` returned stays readable until later mutations push it out. A
/// root field of the mutation root holds the latest payload of its field,
/// and that is what it keeps, by the selection its own variables resolved.
@MainActor
final class CompletedMutation {
    /// The operation value, under which a later completion of an equal value
    /// takes its place.
    let key: AnyHashable
    private let store: Store
    private let resolved: ResolvedSelection

    init(key: AnyHashable, store: Store, resolved: ResolvedSelection) {
        self.key = key
        self.store = store
        self.resolved = resolved
    }

    func mark(into reachable: inout Set<ObjectIdentifier>) {
        store.mark(resolved, from: store.mutationRoot, into: &reachable)
    }
}

/// The live side of an operation value: its phase, its fetch, its data, and
/// its place among the store's roots. Created by the environment, shared by
/// equal operation values.
@MainActor
@Observable
public final class OperationHandle<Op: Query>: AnyOperationHandle {
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
        if Op.bubbles, let path = Op.Data.missingRequiredField(anchor) {
            return .failed(RequiredFieldError(bubbledToRootOf: Op.name, path: path))
        }
        return .ready(data)
    }

    /// Whether the store holds every field the operation selects.
    public var isComplete: Bool { store.check(resolved) != .miss }

    /// Whether the data predates `Environment.invalidate()` or the expiration.
    /// A handle that is loading, or failed with no data behind the failure,
    /// has nothing to go stale; one failed on field errors or a `@required`
    /// null has its data in the store, and it ages as ready data does.
    public var isStale: Bool {
        switch phase {
        case .ready, .failed(is FieldErrors), .failed(is RequiredFieldError):
            break
        case .loading, .failed:
            return false
        }
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
        // data that is still fresh, it is not made again. A parked handle
        // saw no commit since that fetch, so its phase is settled here.
        if preloaded {
            preloaded = false
            if task != nil { return }
            if case .ready = phase, !isStale {
                reevaluate()
                return
            }
        }
        if policy == .networkOnly {
            // What the store holds is not asked; a handle no one shows yet
            // waits for its own response.
            if retainCount == 0 { phase = .loading }
            fetch()
            return
        }
        let answer = store.check(resolved)
        let complete = answer != .miss
        // The deferred parts the store holds half are cleared and fetched;
        // the initial part renders meanwhile.
        let partial = complete && Op.hasDeferred && !store.deferredPartsHold(resolved)
        if complete { takeAge(hydrated: answer == .image) }
        if complete {
            switch phase {
            case .loading:
                phase = evaluate()
            // A parked handle saw no commit: what it failed on may be gone,
            // and a field error or a null may have come.
            case .ready, .failed(is FieldErrors), .failed(is RequiredFieldError):
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
            // An error the last response carried with no field to hold it
            // is in no record a commit could clear; only a fetch clears it.
            let failsUnplaced = Op.throwsOnFieldError && !unplaced.isEmpty
            if !complete || partial || isStale || failsUnplaced { fetch() }
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
                phase = .failed(EnvironmentError.gone)
            }
            return
        }
        // A view shows data while it refreshes: ready data, or the data a
        // failure on field errors or a `@required` null has in the store.
        switch phase {
        case .ready, .failed(is FieldErrors), .failed(is RequiredFieldError):
            isRefreshing = true
        case .loading, .failed:
            break
        }
        task = Task { [weak self] in
            guard let self, let environment else { return nil }
            var failure: (any Error)?
            do {
                let fetched = try await environment.fetch(operation, resolved: resolved) { [weak self] firstPart in
                    // A deferred response renders its first part at once, by
                    // the errors that part carried with no field to hold
                    // them; it is fetched, and fresh, once the stream
                    // completes.
                    guard let self, !Task.isCancelled else { return }
                    unplaced = firstPart.unplaced
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
                // A failure with data behind it stays as well, so a later
                // commit or attach can still settle it by that data.
                switch phase {
                case .ready, .failed(is FieldErrors), .failed(is RequiredFieldError):
                    return error
                case .loading, .failed:
                    phase = .failed(error)
                }
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

/// The handle a view's storage holds, kept in the view's state and released
/// when SwiftUI drops that state. The deinit runs on the main actor, where
/// the handle lives: in place when the last reference goes there, and
/// enqueued on it otherwise.
@MainActor
final class RetainedHandle<Handle: AnyOperationHandle> {
    var handle: Handle?

    isolated deinit {
        handle?.release()
    }
}

/// What a `@Query` property expands to: owns the handle for the view's
/// lifetime, retains it while the view lives, and hands out the operation
/// value with the handle attached.
@MainActor
public struct OperationStorage<Op: Query>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var retained = RetainedHandle<OperationHandle<Op>>()
    private let value: Op
    private let fetchPolicy: FetchPolicy

    public init(_ value: Op, fetchPolicy: FetchPolicy = .default) {
        self.value = value
        self.fetchPolicy = fetchPolicy
    }

    /// Resolves the value to a handle when the value or the environment the
    /// view sees changed: a handle belongs to the environment that made it.
    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            let current = Environment.resolve(environment)
            if retained.handle?.operation != value || retained.handle?.environment !== current {
                retained.handle?.release()
                let handle = current.handle(for: value, fetchPolicy: fetchPolicy)
                handle.retain()
                retained.handle = handle
            }
        }
    }

    /// The value, resolved. Outside a view it is unresolved and reads as loading.
    public var resolved: Op {
        var resolved = value
        resolved.resolution = retained.handle
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
public struct MutationAction<Op: Mutation>: Sendable {
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
public struct MutationStorage<Op: Mutation>: DynamicProperty {
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
public final class SubscriptionHandle<Op: Subscription>: AnyOperationHandle {
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
                        // the stream goes on. The ingest runs to its end
                        // whoever cancelled the task meanwhile.
                        guard !Task.isCancelled else { return }
                        error = failure
                    }
                }
            } catch is CancellationError {
                // A transport that cancelled its own work ended the stream,
                // with nothing to show; a cancellation of this task returns
                // below.
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
        start()
    }

    /// Balances `retain()`. At zero the stream closes; nothing is buffered.
    public func release() {
        retainCount -= 1
        if retainCount <= 0 {
            retainCount = 0
            cancel()
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
extension Subscription {
    /// The live side, which the storage that resolved the value holds.
    @MainActor public var subscription: SubscriptionHandle<Self>? { resolution }
}

/// What a `@Subscription` property expands to: subscribes while the view
/// lives, closes the stream when SwiftUI drops the view's state, and hands out
/// the operation value with the handle attached.
@MainActor
public struct SubscriptionStorage<Op: Subscription>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var retained = RetainedHandle<SubscriptionHandle<Op>>()
    private let value: Op

    public init(_ value: Op) {
        self.value = value
    }

    /// Resolves the value to a handle when the value or the environment the
    /// view sees changed.
    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            let current = Environment.resolve(environment)
            if retained.handle?.operation != value || retained.handle?.environment !== current {
                retained.handle?.release()
                let handle = current.subscriptionHandle(for: value)
                handle.retain()
                retained.handle = handle
            }
        }
    }

    /// The value with its handle attached; `subscription` reaches the live
    /// side through it.
    public var resolved: Op {
        var resolved = value
        resolved.resolution = retained.handle
        return resolved
    }
}
