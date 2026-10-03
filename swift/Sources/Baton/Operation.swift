import Observation
import SwiftUI

public enum OperationKind: Sendable {
    case query, mutation, subscription
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

extension Operation {
    /// Loading until resolved inside a view.
    @MainActor public var phase: Phase<Data> { resolution?.phase ?? .loading }

    /// Whether a fetch is running while earlier data stays visible.
    @MainActor public var isRefreshing: Bool { resolution?.isRefreshing ?? false }

    /// Fetches again and commits; the data stays visible meanwhile.
    @MainActor public func refetch() async { await resolution?.refetch() }

    /// After a failure, fetches again.
    @MainActor public func retry() { resolution?.retry() }
}

/// The live side of an operation value: its phase, its fetch, its data.
/// Created by the environment, shared by equal operation values.
@MainActor
@Observable
public final class OperationHandle<Op: Operation> {
    public let operation: Op
    public private(set) var phase: Phase<Op.Data> = .loading
    public private(set) var isRefreshing = false
    @ObservationIgnored private unowned let environment: Environment
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let resolved: ResolvedSelection

    init(operation: Op, environment: Environment) {
        self.operation = operation
        self.environment = environment
        resolved = Op.plan.resolve(operation.variables)
        // Store-and-network: render what is present now, fetch regardless.
        if environment.store.check(resolved) {
            phase = .ready(data)
        }
        start()
    }

    private var data: Op.Data {
        Op.Data(anchor: Anchor(record: environment.store.root, variables: operation.variables, store: environment.store))
    }

    private func start() {
        task?.cancel()
        if case .ready = phase { isRefreshing = true }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await environment.fetch(operation)
                guard !Task.isCancelled else { return }
                phase = .ready(data)
            } catch is CancellationError {
                return
            } catch {
                if case .ready = phase {
                    // Keep showing data; surface the failure through isRefreshing only.
                } else {
                    phase = .failed(error)
                }
            }
            isRefreshing = false
        }
    }

    public func refetch() async {
        start()
        await task?.value
    }

    public func retry() {
        if case .failed = phase { phase = .loading }
        start()
    }
}

/// What a `@Query` property expands to: owns the handle for the view's
/// lifetime and hands out the operation value with the handle attached.
@MainActor
public struct OperationStorage<Op: Operation>: DynamicProperty {
    @SwiftUI.Environment(\.baton) private var environment
    @State private var box = Box()
    private let value: Op

    @MainActor final class Box {
        var handle: OperationHandle<Op>?
    }

    public init(_ value: Op) {
        self.value = value
    }

    public nonisolated mutating func update() {
        MainActor.assumeIsolated {
            if box.handle?.operation != value {
                box.handle = Environment.resolve(environment).handle(for: value)
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
