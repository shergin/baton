import SwiftUI

/// Store plus transport plus configuration, in Relay's sense. One per backend,
/// injected through SwiftUI's environment as `\.baton`.
@MainActor
public final class Environment {
    public let store: Store
    public let transport: any Transport
    private var handles: [AnyHashable: AnyObject] = [:]

    public init(transport: any Transport, store: Store = Store()) {
        self.store = store
        self.transport = transport
    }

    public convenience init(url: URL, headers: [String: String] = [:]) {
        self.init(transport: URLSessionTransport(url: url, headers: headers))
    }

    /// The handle for an operation value, shared by every view that holds an
    /// equal value. Creating it checks the store and starts the fetch.
    public func handle<Op: Operation>(for operation: Op) -> OperationHandle<Op> {
        if let existing = handles[AnyHashable(operation)] as? OperationHandle<Op> { return existing }
        let handle = OperationHandle(operation: operation, environment: self)
        handles[AnyHashable(operation)] = handle
        return handle
    }

    /// Starts fetching an operation before any view asks for it.
    @discardableResult
    public func preload<Op: Operation>(_ operation: Op) -> OperationHandle<Op> {
        handle(for: operation)
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
