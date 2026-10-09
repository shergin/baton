import Foundation
import Observation

/// The stream a subscription handle holds, as a value read beside its
/// events: not started, or parked while the environment is inactive;
/// connecting until the first event; open; waiting to reconnect after a
/// failure, until the instant it tries again; or ended, by the server's
/// completion, by a request error or an environment failure, or by the
/// environment's end. Not a phase: a subscription has
/// no data of its own to wait for, so it has no loading.
public enum Stream: Sendable {
    case idle
    case connecting
    case open
    /// A failure ended the stream, in `error`, and the handle opens it again
    /// at the instant, by its fixed backoff.
    case waiting(until: ContinuousClock.Instant)
    /// The server completed the stream (`nil`), or a failure ended it for
    /// good: a request error, an environment failure, a handle no longer
    /// retained, or the environment's end.
    case ended(Failure?)

    /// Whether the stream is connecting or open.
    public var isActive: Bool {
        switch self {
        case .connecting, .open: true
        case .idle, .waiting, .ended: false
        }
    }
}

/// The backoff before a failed stream is opened again: a step that doubles
/// from one second to thirty, jittered to between half and the whole of it,
/// reset by an event. Fixed: no server has shown constants of its own to be
/// needed, and a settings bag is refused. The base is a package knob for
/// tests alone.
@MainActor
package enum SubscriptionBackoff {
    package static var base: Duration = .seconds(1)
    static let cap: Duration = .seconds(30)

    static func delay(_ attempt: Int) -> Duration {
        let step = min(base * (1 << min(attempt, 10)), cap)
        return step / 2 + step / 2 * Double.random(in: 0...1)
    }
}

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
    /// The stream, as a value: idle, connecting, open, waiting to reconnect,
    /// or ended.
    public private(set) var stream: Stream = .idle
    /// Whether the stream is connecting or open.
    public var isActive: Bool { stream.isActive }
    /// How many times the stream was opened again after it had been open or
    /// had failed: after a failure's backoff, or after the environment was
    /// inactive. Events may have been missed across each; an owner that
    /// observes the count refetches its baseline.
    public private(set) var resumptions = 0
    /// Whether the environment's inactivity closed the stream while the
    /// handle stayed retained, so activity opens it again.
    @ObservationIgnored private var parked = false
    /// The environment that made the handle; releasing the handle after it
    /// is gone does nothing.
    @ObservationIgnored private(set) weak var environment: Environment?
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The operation's name and variables, as the image names it.
    @ObservationIgnored let key: String
    /// The handle's root among the store's, while retained.
    @ObservationIgnored let root: Store.Root
    @ObservationIgnored var resolved: ResolvedSelection { root.resolved }
    /// The scope every event's lens reads in.
    @ObservationIgnored private let owner: Owner

    init(operation: Op, key: String, environment: Environment) {
        self.operation = operation
        self.key = key
        self.environment = environment
        store = environment.store
        root = environment.store.root(key, resolved: Op.plan.resolve(operation.variables, in: environment.store.keys), record: environment.store.subscriptionRoot)
        owner = Owner(variables: operation.variables, store: environment.store, environment: environment)
    }

    /// How many hold the stream open; for the tests.
    package var retainCount: Int { root.holders }

    /// Opens the stream unless it is open, or its environment is gone.
    func start() {
        guard task == nil, let current = environment, !current.ended else { return }
        // Retained while the environment is inactive: the stream waits parked
        // for activity, as one closed by inactivity does.
        guard current.isActive else {
            parked = true
            stream = .idle
            return
        }
        parked = false
        stream = .connecting
        error = nil
        task = Task { [weak self] in
            guard let self, let environment else { return }
            var attempt = 0
            while true {
                // How the stream ended, written once the task is known not
                // to have been replaced: the stream a newer one replaced
                // leaves the newer one's state be.
                var ending: Stream = .ended(nil)
                var failed = false
                do {
                    for try await payload in environment.subscribe(operation) {
                        guard !Task.isCancelled else { return }
                        do {
                            // The door checks the task's cancellation before
                            // the commit: a stream commits until its task ends.
                            _ = try await environment.commit(payload, plan: resolved, root: root)
                            events += 1
                            latest = Op.Data(anchor: Anchor(record: store.subscriptionRoot, owner: owner))
                            error = nil
                            stream = .open
                            attempt = 0
                        } catch let failure as GraphQLErrors {
                            // An event with errors and no data is one bad event;
                            // the stream goes on. The ingest runs to its end
                            // whoever cancelled the task meanwhile.
                            guard !Task.isCancelled else { return }
                            error = failure
                        } catch is CancellationError {
                            return
                        }
                    }
                } catch is CancellationError {
                    // A transport that cancelled its own work ended the
                    // stream, with nothing to show; a cancellation of this
                    // task returns below.
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error
                    ending = .ended(Failure(error))
                    failed = true
                }
                guard !Task.isCancelled else { return }
                // A failure while the handle is retained is a wait, not an
                // end: the stream is opened again by the backoff. The server's
                // completion ends it, and so does a request error, the
                // server's refusal of the operation as written, and an
                // environment failure, such as a missing subscription
                // transport the environment cannot gain after its creation.
                // The backoff would only repeat either; a retry may try.
                let final = switch ending {
                case .ended(.request?), .ended(.environment?): true
                default: false
                }
                guard failed, !final, retainCount > 0, !environment.ended else {
                    task = nil
                    stream = ending
                    return
                }
                // Failed while the environment is inactive: parked, so that
                // activity opens the stream again rather than the backoff.
                guard environment.isActive else {
                    task = nil
                    parked = true
                    stream = .idle
                    return
                }
                let delay = SubscriptionBackoff.delay(attempt)
                attempt += 1
                stream = .waiting(until: .now + delay)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Cancelled by a release, a park, a retry or the end,
                    // which set the state.
                    return
                }
                // A cancellation that came after the sleep ended but before
                // this task resumed is the canceller's to state: a retry's
                // newer task or the environment's end is left be.
                guard !Task.isCancelled else { return }
                guard retainCount > 0 else {
                    task = nil
                    stream = .idle
                    return
                }
                resumptions += 1
                stream = .connecting
                error = nil
            }
        }
    }

    /// The environment went inactive: the stream closes while the handle
    /// stays retained, and activity opens it again.
    func park() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        parked = true
        stream = .idle
    }

    /// The environment is active again: a stream parked by its inactivity is
    /// opened again, counted as a resumption.
    func resume() {
        guard parked, retainCount > 0, task == nil else { return }
        resumptions += 1
        start()
    }

    /// Opens the stream again after it ended, by an error or the server's
    /// completion, while the handle is retained.
    public func retry() {
        guard retainCount > 0 else { return }
        cancel()
        start()
    }

    /// Keeps the stream open and the latest event's records alive until the
    /// retention ends.
    public func retain() -> Retention {
        store.retain(root, allowingNetwork: true)
        environment?.didRetain(self)
        start()
        return Retention(self, allowsNetwork: true)
    }

    /// A retention ended. At no holder the stream closes and the root leaves
    /// at once; nothing is buffered.
    func release(allowingNetwork: Bool) {
        _ = store.release(root, allowingNetwork: allowingNetwork, buffering: false)
        guard root.holders == 0 else { return }
        cancel()
        environment?.didEnd(self)
    }

    func refetchIfStale() {}

    func revalidate() {}

    func fetchForHeal() {}

    /// The environment ended: the stream closes and says so.
    func end() {
        cancel()
        error = EnvironmentError.gone
        stream = .ended(.environment(.gone))
    }

    func cancel() {
        task?.cancel()
        task = nil
        stream = .idle
    }
}

/// A subscription value, resolved inside a view through `@Subscription`.
extension Subscription {
    /// The live side, which the storage that resolved the value holds; nil
    /// outside a view, and in a view outside every environment.
    @MainActor public var subscription: SubscriptionHandle<Self>? { resolution.handle }
}
