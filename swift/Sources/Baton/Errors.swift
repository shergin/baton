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

/// A `@required(action: THROW)` field read while null.
public struct RequiredFieldError: Error, Sendable, CustomStringConvertible {
    public let path: String

    public init(path: String) { self.path = path }

    public var description: String { "the @required field \(path) is null" }
}

/// A response that carried errors and no data: the request failed as a whole.
public struct GraphQLErrors: Error, Sendable, CustomStringConvertible {
    public let messages: [String]

    public init(messages: [String]) { self.messages = messages }

    public var description: String { messages.joined(separator: "; ") }
}

/// The `onError` request parameter: how the server should treat field errors.
/// Sent only when the environment sets it.
public enum ErrorBehavior: String, Sendable {
    /// Errors null the field and bubble to the nearest nullable parent (the default).
    case propagate = "PROPAGATE"
    /// Errors null the field and stop there.
    case null = "NULL"
    /// The first error fails the whole request.
    case abort = "ABORT"
}
