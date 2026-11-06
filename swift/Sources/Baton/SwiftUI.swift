import SwiftUI

// The one file of the runtime that imports SwiftUI: the environment value
// views read the Baton environment from, the storages the marker macros
// expand to, and the `ForEach` initializers over lenses. The rest of the
// module is written against Foundation and Observation, and
// `scripts/check-boundaries.sh` keeps it so.

extension EnvironmentValues {
    /// The Baton environment for this view tree. Set it on an ancestor:
    /// `.environment(\.baton, environment)`.
    @Entry public var baton: Baton.Environment? = nil
}

// MARK: Storages

/// The handle a view's storage holds, with the retention that keeps its
/// records alive, kept in the view's state and let go when SwiftUI drops
/// that state. No handle in a view outside every environment.
@MainActor
final class RetainedHandle<Handle: AnyOperationHandle> {
    var handle: Handle?
    var retention: Retention?
}

/// What a `@Query` property expands to: owns the handle for the view's
/// lifetime, retains it while the view lives, hands the value back as it
/// was passed, and the handle's state through the projection.
@MainActor
public struct OperationStorage<Op: Query>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var retained = RetainedHandle<OperationHandle<Op>>()
    private let operation: Op
    private let fetchPolicy: FetchPolicy

    public init(_ value: Op, fetchPolicy: FetchPolicy = .default) {
        operation = value
        self.fetchPolicy = fetchPolicy
    }

    /// Resolves the value to a handle when the value or the environment the
    /// view sees changed: a handle belongs to the environment that made it.
    /// A view outside every environment gets no handle: the absence of an
    /// environment is not a session, and the state says so.
    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            guard let current = environment else {
                retained.handle = nil
                retained.retention = nil
                return
            }
            if retained.handle?.operation != operation || retained.handle?.environment !== current {
                let handle = current.handle(for: operation, fetchPolicy: fetchPolicy)
                retained.retention = handle.retain()
                retained.handle = handle
            }
        }
    }

    /// The value the parent passed, as it is.
    public var value: Op { operation }

    /// The value's live side, which the projection `$name` reads: the handle
    /// the storage resolved it to, or none outside every environment.
    public var state: QueryState<Op> { QueryState(handle: retained.handle) }
}

/// The live side of a query value in a view, what `$issues` reads: the
/// handle the storage resolved the value to in the environment the view
/// sees, or none outside every environment, where the phase reads failed
/// with the fetch's environment kind, not injected. The Swift twin of the
/// Kotlin runtime's `QueryState`.
@MainActor
public struct QueryState<Op: Query> {
    /// The handle, shared by every holder of an equal value; nil outside
    /// every environment.
    public let handle: OperationHandle<Op>?

    init(handle: OperationHandle<Op>?) {
        self.handle = handle
    }

    /// Loading, ready with its lens, or failed with the failure that says
    /// why; failed with the fetch's environment kind, not injected, outside
    /// every environment.
    public var phase: Phase<Op.Data> { handle?.phase ?? .failed(.fetch(.environment(.notInjected))) }

    /// The last fetch: idle, in flight, or failed with its failure and when;
    /// idle where no environment could make one.
    public var fetch: Fetch { handle?.fetch ?? .idle }

    /// Whether a fetch is running while earlier data stays visible.
    public var isRefreshing: Bool { handle?.isRefreshing ?? false }

    /// Whether the data predates an invalidation or the cache expiration.
    public var isStale: Bool { handle?.isStale ?? false }

    /// When the store last committed the operation's response: the root's
    /// age, in this launch or, from the image, an earlier one.
    public var fetchTime: ContinuousClock.Instant? { handle?.fetchTime }

    /// Fetches again and commits; the data stays visible meanwhile, and the
    /// failure the phase would show is thrown here instead. Outside every
    /// environment it throws the fetch's environment kind, not injected.
    public func refetch() async throws(PhaseFailure) {
        guard let handle else { throw .fetch(.environment(.notInjected)) }
        try await handle.refetch()
    }

    /// After a failure, fetches again. A failure on field errors or a
    /// `@required` null keeps its data visible meanwhile, as a refetch does;
    /// any other shows loading.
    public func retry() { handle?.retry() }
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

/// What a `@Subscription` property expands to: subscribes while the view
/// lives, closes the stream when SwiftUI drops the view's state, hands the
/// value back as it was passed, and the handle through the projection.
@MainActor
public struct SubscriptionStorage<Op: Subscription>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var retained = RetainedHandle<SubscriptionHandle<Op>>()
    private let operation: Op

    public init(_ value: Op) {
        operation = value
    }

    /// Resolves the value to a handle when the value or the environment the
    /// view sees changed; a view outside every environment gets none.
    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            guard let current = environment else {
                retained.handle = nil
                retained.retention = nil
                return
            }
            if retained.handle?.operation != operation || retained.handle?.environment !== current {
                let handle = current.subscriptionHandle(for: operation)
                retained.retention = handle.retain()
                retained.handle = handle
            }
        }
    }

    /// The value the parent passed, as it is.
    public var value: Op { operation }

    /// The handle the storage holds open, which the projection `$name`
    /// reads; nil outside every environment.
    public var state: SubscriptionHandle<Op>? { retained.handle }
}

// MARK: Lists

extension ForEach where Content: View, ID == RecordID {
    /// Iterates a list of lenses, identified by record.
    @MainActor
    public init<Element: Lens>(_ list: List<Element>, @ViewBuilder content: @escaping (Element) -> Content) where Data == List<Element> {
        self.init(list, id: \.recordID, content: content)
    }

    /// Iterates lenses, identified by record; for a connection's `nodes`.
    @MainActor
    public init<Element: Lens>(_ lenses: [Element], @ViewBuilder content: @escaping (Element) -> Content) where Data == [Element] {
        self.init(lenses, id: \.recordID, content: content)
    }
}
