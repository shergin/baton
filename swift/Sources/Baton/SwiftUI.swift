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
/// that state.
@MainActor
final class RetainedHandle<Handle: AnyOperationHandle> {
    var handle: Handle?
    var retention: Retention?
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
                let handle = current.handle(for: value, fetchPolicy: fetchPolicy)
                retained.retention = handle.retain()
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
                let handle = current.subscriptionHandle(for: value)
                retained.retention = handle.retain()
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
