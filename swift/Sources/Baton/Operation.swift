/// An operation value: the variables of one operation, `Hashable` by them, and
/// resolvable against an environment. Spike stage: resolution is a stub.
public protocol Operation: Hashable, Sendable {
    var resolution: Resolution? { get set }
}

/// What an operation value resolves to inside a view. Spike stage: a stub.
public final class Resolution: @unchecked Sendable {
    public var phase: String = "ready (stub)"
    public init() {}
}

extension Operation {
    /// The operation's phase, or `unresolved` outside a view.
    public var phase: String { resolution?.phase ?? "unresolved" }
}

/// The storage a `@Query` property expands to. It owns the resolution and
/// hands out the operation value with the resolution attached.
public struct OperationStorage<Op: Operation>: Sendable {
    private var value: Op
    private let resolution = Resolution()

    public init(_ value: Op) {
        self.value = value
    }

    public var resolved: Op {
        var resolved = value
        resolved.resolution = resolution
        return resolved
    }
}
