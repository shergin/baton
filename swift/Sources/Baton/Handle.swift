import Foundation
import Observation

/// Type-erased view of a handle, for the environment's bookkeeping. A
/// handle is the main actor's, so it is `Sendable` as a value an operation
/// value carries.
@MainActor
protocol AnyOperationHandle: AnyObject, Sendable {
    /// The operation's name and variables, as the image names it.
    var key: String { get }
    /// The handle's root among the store's.
    var root: Store.Root { get }
    var retainCount: Int { get }
    /// One holder fewer: a retention ended, of a holder whose policy allowed
    /// the network or not.
    func release(allowingNetwork: Bool)
    func refetchIfStale()
    /// Fetches again when the data is stale or the last fetch failed, if a
    /// holder allows the network.
    func revalidate()
    /// Fetches again for a heal, unless a fetch is in flight.
    func fetchForHeal()
    /// The environment ended: what the handle shows says so, and nothing is
    /// fetched again.
    func end()
    func cancel()
    /// The environment went inactive: a stream closes while its handle stays
    /// retained; a query reads nothing of it.
    func park()
    /// The environment is active again: a parked stream opens again.
    func resume()
}

/// The live side of an operation value: a view of its root, which is the
/// store's and holds whether the data is there and what it deserves, and of
/// its fetch, which is the environment's; its phase is derived from the two
/// and stored nowhere. Created by the environment, shared by equal
/// operation values.
@MainActor
@Observable
public final class OperationHandle<Op: Query>: AnyOperationHandle, Store.Judge {
    public let operation: Op
    /// The last fetch, as a value: idle, in flight, or failed with its
    /// failure and when it failed. A fetch that fails behind data leaves the
    /// phase as it was and is read here, by every view of the handle.
    public private(set) var fetch: Fetch = .idle
    /// Whether the environment ended: the handle reads gone, whatever the
    /// store holds.
    private var ended = false
    /// Whether a `storeOnly` attach found the store without the data; the
    /// phase says so until the data comes or a fetch is started by hand.
    private var missingData = false
    /// Whether a `networkOnly` attach by a view nobody shows the handle to
    /// waits for its own response: loading until it lands, whatever the
    /// store holds meanwhile.
    private var awaitsOwnResponse = false
    /// When the store last committed the operation's response, in this launch
    /// or, from the image, an earlier one: the root's age.
    public var fetchTime: ContinuousClock.Instant? { root.fetchTime }
    /// The environment that made the handle. A view may release its handle
    /// after the environment is gone, which then does nothing.
    @ObservationIgnored private(set) weak var environment: Environment?
    @ObservationIgnored private let store: Store
    /// The operation's name and variables, as the image names it.
    @ObservationIgnored let key: String
    /// The handle's root among the store's: what keeps its records alive.
    @ObservationIgnored let root: Store.Root
    /// The fetch in flight; its value is the failure it ended with.
    @ObservationIgnored private var task: Task<(any Error)?, Never>?
    @ObservationIgnored var resolved: ResolvedSelection { root.resolved }
    /// The scope every lens of the handle reads in.
    @ObservationIgnored private let owner: Owner
    /// Set by a `preload` that fetched: the first attach finds the fetch
    /// made, or on the way.
    @ObservationIgnored var preloaded = false
    /// The policy of the last attach, which the retention it makes keeps.
    @ObservationIgnored private var lastPolicy: FetchPolicy = .default
    /// The field errors of the last fetch that no field in the store holds,
    /// which `@throwOnFieldError` counts until the next fetch: the network's
    /// fact, kept here and weighed with the root's verdict.
    private var unplaced: [FieldError] = []

    init(operation: Op, key: String, environment: Environment) {
        self.operation = operation
        self.key = key
        self.environment = environment
        store = environment.store
        root = environment.store.root(key, resolved: Op.plan.resolve(operation.variables, in: environment.store.keys), record: environment.store.root)
        owner = Owner(variables: operation.variables, store: environment.store, environment: environment, root: root)
        // An operation with a policy judges its root's data.
        if Op.throwsOnFieldError || Op.bubbles { root.judge = self }
    }

    /// What the data deserves: generated code's walk of the operation's own
    /// selection, as Relay's reader of the operation weighs it (a spread's
    /// fragment weighs its own). The root asks after a batch that changed
    /// what the verdict reads, and when the data is found or fetched.
    func judge() -> Store.Verdict {
        if Op.throwsOnFieldError {
            let errors = Op.Data.fieldErrors(anchor)
            if !errors.isEmpty { return .fieldErrors(errors) }
        }
        if Op.bubbles, let path = Op.Data.missingRequiredField(anchor) {
            return .requiredMissing(path: path)
        }
        return .sound
    }

    /// How many hold the handle's root; for the tests.
    package var retainCount: Int { root.holders }

    /// The phase, derived and never stored. With the data in the store it is
    /// what the data deserves: the root's verdict, weighed with the errors
    /// the last response carried that no field holds, read without the
    /// fetch, so a fetch that changed nothing wakes no body that reads the
    /// phase. Without the data it is what the network did: loading, or the
    /// fetch's failure. An ended environment reads gone whatever the store
    /// holds; a `storeOnly` attach that found no data reads so until the
    /// data comes; a `networkOnly` attach nobody shows waits for its own
    /// response.
    public var phase: Phase<Op.Data> {
        if ended { return .failed(EnvironmentError.gone) }
        guard root.present, !awaitsOwnResponse else {
            if case .failed(let failure, _) = fetch { return .failed(failure.error) }
            if missingData { return .failed(MissingDataError(operationName: Op.name)) }
            return .loading
        }
        if Op.throwsOnFieldError {
            var errors = unplaced
            if case .fieldErrors(let found) = root.verdict { errors += found }
            if !errors.isEmpty { return .failed(FieldErrors(errors)) }
        }
        if Op.bubbles, case .requiredMissing(let path) = root.verdict {
            return .failed(RequiredFieldError(bubbledToRootOf: Op.name, path: path))
        }
        return .ready(data)
    }

    /// Whether a fetch is in flight.
    var isFetching: Bool { task != nil }

    /// Whether a fetch is running while earlier data stays visible: data
    /// present and a fetch in flight. Nothing refreshes behind loading, nor
    /// behind a failure with no data in the store.
    public var isRefreshing: Bool {
        guard case .inFlight = fetch else { return false }
        return showsData
    }

    /// Whether the phase shows data: the store holds it and the handle shows
    /// it, ready or failed on what the data deserves, which ages as ready
    /// data does.
    private var showsData: Bool { root.present && !awaitsOwnResponse && !ended }

    private var anchor: Anchor {
        Anchor(record: store.root, owner: owner)
    }

    private var data: Op.Data { Op.Data(anchor: anchor) }

    /// Whether the store holds every field the operation selects; for the
    /// tests.
    package var isComplete: Bool { store.check(resolved) != .miss }

    /// Whether the data predates `Environment.invalidate()` or is older than
    /// the operation's expiration, `@cacheExpiration(seconds:)` in its
    /// document, or the store's default when it states none. A handle that
    /// is loading, or failed with no data behind the failure, has nothing to
    /// go stale; one failed on field errors or a `@required` null has its
    /// data in the store, and it ages as ready data does.
    public var isStale: Bool {
        guard showsData else { return false }
        if root.fetchEpoch < store.invalidationEpoch { return true }
        guard let expiration = Op.cacheExpiration ?? store.cacheExpiration else { return false }
        // Data with no known age is stale wherever an expiration applies: the
        // rule hydration has, in memory too.
        guard let fetchTime = root.fetchTime else { return true }
        return fetchTime + expiration < store.now
    }

    /// Applies a policy on attach: renders what the store allows, fetches
    /// when the policy asks for it.
    func apply(_ policy: FetchPolicy) {
        lastPolicy = policy
        // A preload's fetch is the first attach's: in flight, or done with
        // data that is still fresh, it is not made again. A parked handle
        // saw no commit since that fetch, so its phase is settled here.
        if preloaded {
            preloaded = false
            if task != nil { return }
            if root.present, !isStale {
                // A parked handle saw no commit since the preload's fetch:
                // its verdict is settled here.
                root.found()
                return
            }
        }
        if policy == .networkOnly {
            // What the store holds is not asked; a handle no one shows yet
            // waits for its own response, which may be a refetch in flight:
            // nothing shows behind it.
            if retainCount == 0 { awaitsOwnResponse = true }
            fetchUnlessInFlight()
            return
        }
        let answer = store.check(resolved)
        let complete = answer != .miss
        // The deferred parts the store holds half are cleared and fetched;
        // the initial part renders meanwhile.
        let partial = complete && Op.hasDeferred && !store.deferredPartsHold(resolved)
        if complete {
            store.takeAge(root, hydrated: answer == .image)
            // The data is there, and its verdict is settled on it: a parked
            // handle saw no commit, so what it failed on may be gone and a
            // field error or a null may have come.
            root.found()
        }
        switch policy {
        case .storeOnly:
            if !complete, !root.present { missingData = true }
        case .storeOrNetwork:
            // An error the last response carried with no field to hold it
            // is in no record a commit could clear; only a fetch clears it.
            let failsUnplaced = Op.throwsOnFieldError && !unplaced.isEmpty
            if !complete || partial || isStale || failsUnplaced { fetchUnlessInFlight() }
        case .storeAndNetwork, .networkOnly:
            fetchUnlessInFlight()
        }
    }

    /// Starts a fetch unless one is in flight.
    func fetchUnlessInFlight() {
        guard task == nil else { return }
        start()
    }

    private func start() {
        task?.cancel()
        // A fetch started by hand on a `storeOnly` handle supersedes what the
        // attach found missing: the network answers now.
        missingData = false
        guard let current = environment, !current.ended else {
            // Nothing can fetch for a handle whose environment is gone or
            // ended: it keeps the data it shows and says why it cannot load
            // more; without data the phase reads the failure.
            task = nil
            fetch = .failed(.environment(.gone), at: store.now)
            return
        }
        fetch = .inFlight
        task = Task { [weak self] in
            guard let self, let environment else { return nil }
            var failure: (any Error)?
            do {
                let committed = try await environment.fetch(operation, resolved: resolved) { [weak self] firstPart in
                    // A deferred response renders its first part at once, by
                    // the errors that part carried with no field to hold
                    // them; it is fetched, and fresh, once the stream
                    // completes.
                    guard let self, !Task.isCancelled else { return }
                    unplaced = firstPart.unplaced
                    awaitsOwnResponse = false
                    root.committed()
                }
                if !Task.isCancelled { unplaced = committed.unplaced }
            } catch {
                failure = error
            }
            // A cancelled fetch was superseded or evicted. The handle's state
            // belongs to whoever cancelled it, however the fetch ended.
            guard !Task.isCancelled else { return nil }
            task = nil
            switch failure {
            case nil:
                // The door dated the root and made its data present.
                fetch = .idle
                awaitsOwnResponse = false
                // A response whose field errors fail the operation fails its
                // refetch the same way.
                if case .failed(let error) = phase { return error }
            case is CancellationError:
                // The transport cancelled its own work: nothing to show.
                fetch = .idle
                return nil
            case let error?:
                // The fetch records its failure and when, for every view of
                // the handle; `refetch()` throws the error as well. Data
                // behind the failure stays visible, and so does a failure the
                // data is in the store for, which a later commit or attach
                // can still settle by that data; with nothing to show, the
                // phase reads the failure.
                fetch = .failed(Failure(error), at: store.now)
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

    /// Waits for an in-flight fetch, if any. For the tests and the benchmarks,
    /// until the fetch is a value a reader awaits.
    package func settle() async {
        _ = await task?.value
    }

    /// After a failure, fetches again. A failure on field errors or a
    /// `@required` null stays in place, its data visible, and the fetch
    /// refreshes behind it as `refetch()` does: a fetch that fails at the
    /// transport leaves it for a later commit or attach to settle. Any other
    /// failure shows loading meanwhile, since the fetch in flight is what
    /// the phase reads without data.
    public func retry() {
        start()
    }

    /// Keeps the operation's records alive until the retention ends. `@Query`
    /// holds one for a view's lifetime; a model or a view controller holds
    /// one in a property and lets it go with itself.
    public func retain() -> Retention {
        let allowsNetwork = lastPolicy != .storeOnly
        store.retain(root, allowingNetwork: allowsNetwork)
        environment?.didRetain(self)
        return Retention(self, allowsNetwork: allowsNetwork)
    }

    /// A retention ended. At no holder the root enters the release buffer,
    /// and the handles of the roots it pushes out go with their fetches.
    func release(allowingNetwork: Bool) {
        let evicted = store.release(root, allowingNetwork: allowingNetwork)
        environment?.evict(evicted)
    }

    /// A fetch the runtime starts asks whether a holder allows the network: a
    /// `storeOnly` holder is fetched for by neither an invalidation nor a
    /// revalidation nor a heal.
    func refetchIfStale() {
        if isStale, root.allowsNetwork { fetchUnlessInFlight() }
    }

    func revalidate() {
        guard root.allowsNetwork else { return }
        if isStale { fetchUnlessInFlight() }
        if case .failed = fetch { fetchUnlessInFlight() }
    }

    func fetchForHeal() {
        if root.allowsNetwork { fetchUnlessInFlight() }
    }

    /// A query reads nothing of the environment's activity.
    func park() {}
    func resume() {}

    func cancel() {
        task?.cancel()
        task = nil
        fetch = .idle
    }

    /// The environment ended: the fetch in flight is cancelled, the phase
    /// says gone to its observers, and the records the data read are the
    /// store's to clear.
    func end() {
        cancel()
        fetch = .failed(.environment(.gone), at: store.now)
        ended = true
    }
}
