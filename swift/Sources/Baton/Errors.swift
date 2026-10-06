import Foundation

// Every public error is a `LocalizedError`, so that `localizedDescription`,
// which the platform's alerts and logs read, shows the text the error
// already carries rather than the type's name.

/// A field error the server reported, stored beside the field it names so a
/// cached read sees what the network read saw.
public struct FieldError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    /// The response path, dotted, with list indices: `character.episode.2.name`.
    public let path: String
    /// The server's `extensions` for the error, a JSON value, when it sent
    /// any: an app branches on a code in it, never on the message.
    public let extensions: Variable?

    public init(message: String, path: String, extensions: Variable? = nil) {
        self.message = message
        self.path = path
        self.extensions = extensions
    }

    /// The error a `@required(action: THROW)` field that is null raises.
    public static func required(path: String) -> FieldError {
        FieldError(message: "the @required field is null", path: path)
    }

    /// The error a `@catch` on a non-null mapped scalar carries when the
    /// field is null or missing: it has no zero to read as.
    public static func null(path: String) -> FieldError {
        FieldError(message: "the non-null field is null", path: path)
    }

    /// The error a mapped scalar raises when its text does not convert to
    /// the type the field reads as.
    public static func conversion<T>(path: String, to type: T.Type) -> FieldError {
        FieldError(message: "the value does not convert to \(type)", path: path)
    }

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
    public var errorDescription: String? { description }
}

/// The field errors a `@catch` collected or a `@throwOnFieldError` threw.
public struct FieldErrors: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let errors: [FieldError]

    public init(_ errors: [FieldError]) { self.errors = errors }

    public var description: String { errors.map(\.description).joined(separator: "; ") }
    public var errorDescription: String? { description }
}

/// A `@required(action: THROW)` field read while null, or the root of an
/// operation that a `@required` field bubbled to.
public struct RequiredFieldError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The field's path: the one read, or the one that bubbled to the root.
    public let path: String
    /// The operation whose root bubbled; nil for a field read while null.
    public let operationName: String?

    public init(path: String) {
        self.path = path
        operationName = nil
    }

    init(bubbledToRootOf operationName: String, path: String) {
        self.path = path
        self.operationName = operationName
    }

    public var description: String {
        guard let operationName else { return "the @required field \(path) is null" }
        return "\(operationName): the @required field \(path) is null and bubbled to the root"
    }

    public var errorDescription: String? { description }
}

/// A request with nothing to send it: no environment where one was needed,
/// or an environment without the transport the operation runs over.
public enum EnvironmentError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// A view outside every `.environment(\.baton, ...)` asked for data.
    case notInjected
    /// A lens read outside an environment's store asked to fetch.
    case outsideEnvironment
    /// The environment that made a handle is gone, or has ended.
    case gone
    /// A subscription ran in an environment made without `subscriptions:`.
    case noSubscriptionTransport

    public var description: String {
        switch self {
        case .notInjected: "no Baton environment: set `.environment(\\.baton, environment)` on an ancestor view"
        case .outsideEnvironment: "the lens was read outside an environment's store, so it cannot fetch"
        case .gone: "the environment is gone or has ended, so nothing can be fetched"
        case .noSubscriptionTransport: "no subscription transport: pass `subscriptions:` to the environment"
        }
    }

    public var errorDescription: String? { description }
}

/// A response that carried errors and no data: the request failed as a whole.
/// The request kind of a `Failure`.
public struct GraphQLErrors: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The response's errors: each its message, its path when the server
    /// gave one and an empty path otherwise, and its `extensions`.
    public let errors: [FieldError]

    public init(errors: [FieldError]) { self.errors = errors }

    /// Errors of messages alone.
    public init(messages: [String]) {
        errors = messages.map { FieldError(message: $0, path: "") }
    }

    /// The errors' messages.
    public var messages: [String] { errors.map(\.message) }

    public var description: String { messages.joined(separator: "; ") }
    public var errorDescription: String? { description }
}

/// Why a fetch or a stream did not deliver, in one of a closed set of kinds.
/// Field errors are not among them: under `@throwOnFieldError` they fail the
/// phase, as a `@required` field that bubbled does, but they are facts about
/// the data, not failures of a fetch. The transport's kind carries what the
/// transport threw, unchanged, so there is no second vocabulary beside the
/// transport's to drift from it.
public enum Failure: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The transport threw: a `TransportError`, a `URLError`, or an app's own
    /// transport's error, as it was thrown.
    case transport(any Error)
    /// The server answered errors and no data.
    case request(GraphQLErrors)
    /// A response the plan could not read.
    case malformed(IngestError)
    /// Nothing could send the request: no environment, no transport for the
    /// operation's kind, or the environment that made the handle is gone.
    case environment(EnvironmentError)

    /// Classifies what a fetch threw.
    init(_ error: any Error) {
        switch error {
        case let error as GraphQLErrors: self = .request(error)
        case let error as IngestError: self = .malformed(error)
        case let error as EnvironmentError: self = .environment(error)
        default: self = .transport(error)
        }
    }

    /// The error as it was thrown.
    public var error: any Error {
        switch self {
        case .transport(let error): error
        case .request(let error): error
        case .malformed(let error): error
        case .environment(let error): error
        }
    }

    public var description: String {
        switch self {
        case .transport(let error): "the transport failed: \(error)"
        case .request(let error): "the request failed: \(error)"
        case .malformed(let error): "the response could not be read: \(error)"
        case .environment(let error): error.description
        }
    }

    public var errorDescription: String? { description }
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
