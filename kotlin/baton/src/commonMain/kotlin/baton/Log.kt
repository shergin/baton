package baton

import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration

/**
 * What the runtime did and what went wrong, one event at a time, for the
 * app's own logging and metrics: names and counts, never a record, a slot, a
 * value, a variable or a response body, so routing it anywhere logs nothing
 * a user typed. Relay's word; an app sets `Environment.log`. See
 * `spec/runtime.md`, section 10. The image's events arrive on its writer's
 * thread, off the store's.
 */
sealed interface LogEvent {
    /** How a fetch failed, by the kind of its `Failure`. */
    enum class FailureKind {
        TRANSPORT, REQUEST, MALFORMED, ENVIRONMENT, CANCELLED;

        companion object {
            /** The kind of a thrown error, as `Failure` classifies it. */
            fun of(error: Throwable): FailureKind {
                if (error is CancellationException) return CANCELLED
                return when (Failure.of(error)) {
                    is Failure.Transport -> TRANSPORT
                    is Failure.Request -> REQUEST
                    is Failure.Malformed -> MALFORMED
                    is Failure.Environment -> ENVIRONMENT
                }
            }
        }
    }

    /** The kind of batch a commit was. */
    enum class CommitKind { SERVER, OPTIMISTIC }

    /** A fetch of the operation began. */
    data class FetchStarted(val operation: String) : LogEvent

    /** A fetch of the operation committed its response, in [duration]. */
    data class FetchCompleted(val operation: String, val duration: Duration) : LogEvent

    /** A fetch of the operation threw. */
    data class FetchFailed(val operation: String, val kind: FailureKind) : LogEvent

    /**
     * A batch of the kind ended; [changed] is the slots whose value changed
     * in records that existed, the ones readers were notified of. A record
     * the batch created counts nothing, since nothing had read it.
     */
    data class Committed(val kind: CommitKind, val changed: Int) : LogEvent

    /**
     * A fetch's response carried a field error no `@catch` handled, at the
     * response path; under `@throwOnFieldError` the fetch fails with it as
     * well. Relay reports these through its field logger.
     */
    data class FieldError(val operation: String, val path: String) : LogEvent

    /** A lens read a field the store never received; the miss was recorded and the heal asked for it. */
    data class Missing(val type: String, val field: String) : LogEvent

    /** A lens read a value its type cannot hold, a null in a non-null field or a value of another kind; it read as a zero value or null. */
    data class Unexpected(val type: String, val field: String) : LogEvent

    /** A bare id names live records of several types, so a deletion or a typeless lookup could not tell which; nothing was done. */
    data class AmbiguousIdentity(val id: String, val types: List<String>) : LogEvent

    /** A `@required(action: LOG)` field is null; its lens reads as null. */
    data class RequiredFieldMissing(val type: String, val path: String) : LogEvent

    /** A part of a deferred response named a place the store or the plan does not have, and was dropped; [path] is the response path it named. */
    data class PartDropped(val path: String) : LogEvent

    /** The image's file was opened, or taken again. */
    data object ImageOpened : LogEvent

    /** The image's file could not be opened: locked, foreign, or failing; the writer keeps its work for the next try, and a read meanwhile misses. */
    data object ImageUnavailable : LogEvent

    /** The writer landed [batches] batches of work in the image. */
    data class ImageWritten(val batches: Int) : LogEvent

    /** A write to the image failed; its work waits for the next try, or is lost with a file too damaged to keep. */
    data object ImageWriteFailed : LogEvent
}

/** The line a debug environment prints for a missing-data event until a log is set; null for every other event. */
internal val LogEvent.debugText: String?
    get() = when (this) {
        is LogEvent.Missing -> "Baton: missing data: $type.$field was read but never fetched; the miss was recorded"
        is LogEvent.Unexpected -> "Baton: $type.$field holds a value its reader's type cannot hold; it read as a zero value or null"
        is LogEvent.AmbiguousIdentity -> "Baton: the id $id names records of ${types.joinToString(", ")}; nothing was done for it"
        is LogEvent.RequiredFieldMissing -> "Baton: the @required field $path of $type is null; its lens reads as null"
        else -> null
    }
