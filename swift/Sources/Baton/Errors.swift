/// A field error the server reported, stored beside the field it names so a
/// cached read sees what the network read saw.
public struct FieldError: Error, Hashable, Sendable, CustomStringConvertible {
    public let message: String
    /// The response path, dotted, with list indices: `character.episode.2.name`.
    public let path: String

    public init(message: String, path: String) {
        self.message = message
        self.path = path
    }

    /// The error a `@required(action: THROW)` field that is null raises.
    public static func required(path: String) -> FieldError {
        FieldError(message: "the @required field is null", path: path)
    }

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// The field errors a `@catch` collected or a `@throwOnFieldError` threw.
public struct FieldErrors: Error, Sendable, CustomStringConvertible {
    public let errors: [FieldError]

    public init(_ errors: [FieldError]) { self.errors = errors }

    public var description: String { errors.map(\.description).joined(separator: "; ") }
}

/// A `@required(action: THROW)` field read while null, or the root of an
/// operation that a `@required` field bubbled to.
public struct RequiredFieldError: Error, Sendable, CustomStringConvertible {
    /// The field's path; empty for a root, whose generated check says only
    /// that a field below it bubbled, not which.
    public let path: String
    /// The operation whose root bubbled; nil for a field read while null.
    public let operationName: String?

    public init(path: String) {
        self.path = path
        operationName = nil
    }

    init(bubbledToRootOf operationName: String) {
        path = ""
        self.operationName = operationName
    }

    public var description: String {
        guard let operationName else { return "the @required field \(path) is null" }
        return "\(operationName): a @required field is null and bubbled to the root"
    }
}

/// A request with nothing to send it: no environment where one was needed,
/// or an environment without the transport the operation runs over.
public enum EnvironmentError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A view outside every `.environment(\.baton, ...)` asked for data.
    case notInjected
    /// A lens read outside an environment's store asked to fetch.
    case outsideEnvironment
    /// The environment that made a handle is gone.
    case gone
    /// A subscription ran in an environment made without `subscriptions:`.
    case noSubscriptionTransport

    public var description: String {
        switch self {
        case .notInjected: "no Baton environment: set `.environment(\\.baton, environment)` on an ancestor view"
        case .outsideEnvironment: "the lens was read outside an environment's store, so it cannot fetch"
        case .gone: "the handle's environment is gone, so it cannot fetch"
        case .noSubscriptionTransport: "no subscription transport: pass `subscriptions:` to the environment"
        }
    }
}

/// A response that carried errors and no data: the request failed as a whole.
public struct GraphQLErrors: Error, Sendable, CustomStringConvertible {
    public let messages: [String]

    public init(messages: [String]) { self.messages = messages }

    public var description: String { messages.joined(separator: "; ") }
}

/// The `onError` request parameter: how the server should treat field errors.
/// Named in `baton.json` and sent with every operation the compiler emits
/// under it; under `NULL` the compiler types the fields the schema calls
/// non-null by their semantic nullability.
public enum ErrorBehavior: String, Sendable {
    /// Errors null the field and bubble to the nearest nullable parent (the default).
    case propagate = "PROPAGATE"
    /// Errors null the field and stop there.
    case null = "NULL"
    /// The first error fails the whole request.
    case abort = "ABORT"
}
