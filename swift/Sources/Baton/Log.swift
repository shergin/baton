import Foundation

/// What the runtime did and what went wrong, one event at a time, for the
/// app's own logging and metrics: names and counts, never a record, a slot,
/// a value, a variable or a response body, so routing it anywhere logs
/// nothing a user typed. Relay's word; an app sets `Environment.log`.
public enum LogEvent: Sendable, Equatable {
    /// How a fetch failed, by the kind of its `Failure`.
    public enum FailureKind: Sendable, Equatable {
        case transport, request, malformed, environment, cancelled
    }

    /// The kind of batch a commit was.
    public enum CommitKind: Sendable, Equatable {
        case server, optimistic
    }

    /// A fetch of the operation began.
    case fetchStarted(operation: String)
    /// A fetch of the operation committed its response, in `duration`.
    case fetchCompleted(operation: String, duration: Duration)
    /// A fetch of the operation threw.
    case fetchFailed(operation: String, kind: FailureKind)
    /// A batch of the kind ended; `changed` is the slots whose value changed
    /// in records that existed, the ones readers were notified of. A record
    /// the batch created counts nothing, since nothing had read it.
    case committed(kind: CommitKind, changed: Int)
    /// A fetch's response carried a field error no `@catch` handled, at the
    /// response path; under `@throwOnFieldError` the fetch fails with it as
    /// well. Relay reports these through its field logger.
    case fieldError(operation: String, path: String)
    /// The image's file was opened, or taken again.
    case imageOpened
    /// The image's file could not be opened: locked, foreign, or failing;
    /// the writer keeps its work.
    case imageUnavailable
    /// The writer landed `batches` batches of work in the image.
    case imageWritten(batches: Int)
    /// The writer's work failed to land; it is kept or dropped as the file
    /// allows.
    case imageWriteFailed
    /// A lens read a field the store never received; the miss was recorded
    /// and the heal asked for it.
    case missing(type: String, field: String)
    /// A lens read a value its type cannot hold: a null in a non-null field,
    /// or a value of another kind; it read as a zero value or nil.
    case unexpected(type: String, field: String)
    /// A bare id names live records of several types, so a deletion or a
    /// typeless lookup could not tell which; nothing was done.
    case ambiguousIdentity(id: String, types: [String])
    /// A `@required(action: LOG)` field is null; its lens reads as null.
    case requiredFieldMissing(type: String, path: String)

    /// The line a debug build prints for the missing-data cases, and nothing
    /// for the rest.
    var debugDescription: String? {
        switch self {
        case .missing(let type, let field):
            "Baton: missing data: \(type).\(field) was read but never fetched; the miss was recorded"
        case .unexpected(let type, let field):
            "Baton: \(type).\(field) holds a value its reader's type cannot hold; it read as a zero value or nil"
        case .ambiguousIdentity(let id, let types):
            "Baton: the id \(id) names records of \(types.joined(separator: ", ")); nothing was done for it"
        case .requiredFieldMissing(let type, let path):
            "Baton: the @required field \(path) of \(type) is null; its lens reads as null"
        default:
            nil
        }
    }
}

extension LogEvent.FailureKind {
    /// The kind of a thrown error, as `Failure` classifies it.
    init(_ error: any Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        switch Failure(error) {
        case .transport: self = .transport
        case .request: self = .request
        case .malformed: self = .malformed
        case .environment: self = .environment
        }
    }
}
