package baton

/**
 * An entry of a response's `errors` that landed on a field: its message, its
 * response path dotted with list indices (`character.episode.2.name`), and
 * the server's `extensions`, when it sent any. It lives beside the field it
 * names, and a `@catch` or a `@throwOnFieldError` surfaces it.
 */
data class FieldError(val message: String, val path: String, val extensions: Variable? = null) {
    override fun toString(): String = "$path: $message"

    companion object {
        /** The error a `@required(action: THROW)` field that is null raises. */
        fun required(path: String): FieldError = FieldError("the @required field is null", path)

        /** The error a `@catch` on a non-null mapped scalar carries when the field is null or missing: it has no zero to read as. */
        fun nullValue(path: String): FieldError = FieldError("the non-null field is null", path)

        /** The error a mapped scalar raises when its text does not convert through the converter the configuration names. */
        fun conversion(path: String, converter: ScalarConverter<*>): FieldError =
            FieldError("the value does not convert through ${converter::class.simpleName}", path)
    }
}

/** The field errors a `@catch` caught or a `@throwOnFieldError` threw, in response order. */
class FieldErrors(val errors: List<FieldError>) : Exception() {
    override val message: String get() = errors.joinToString("; ")
}

/** A `@required(action: THROW)` field that was null, by its response path, bubbled to the operation when it reached the root. */
class RequiredFieldError(val path: String, val operationName: String? = null) : Exception() {
    override val message: String
        get() = if (operationName == null) "required field $path is null" else "required field $path is null, bubbled to the root of $operationName"
}

/** A `storeOnly` operation whose data the store does not hold. */
class MissingDataError(val operationName: String) : Exception() {
    override val message: String get() = "the store holds no data for $operationName"
}

/** What is missing when an operation cannot run: the environment, or a piece of it. */
sealed class EnvironmentError(override val message: String) : Exception() {
    /** A composable outside every `LocalBaton` provider. */
    data object NotInjected : EnvironmentError("no environment is provided above this composable")

    /** A lens made by hand, with no environment to fetch through. */
    data object OutsideEnvironment : EnvironmentError("this lens has no environment to fetch through")

    /** The environment that made the handle has ended. */
    data object Gone : EnvironmentError("the environment has ended")

    /** A subscription with no subscription transport. */
    data object NoSubscriptionTransport : EnvironmentError("the environment has no subscription transport")
}

/** A response whose `errors` carry no path that lands on a field: the request as a whole failed. */
class GraphQLErrors(val errors: List<FieldError>) : Exception() {
    constructor(messages: List<String>, path: String = "") : this(messages.map { FieldError(it, path) })

    val messages: List<String> get() = errors.map { it.message }
    override val message: String get() = messages.joinToString("; ")
}

/** A response outside 2xx, or no response at all (status 0), with what the transport could say. */
class TransportError(val statusCode: Int, val body: String) : Exception() {
    override val message: String get() = if (statusCode == 0) body else "HTTP $statusCode: $body"
}

/** Why a fetch failed, by kind, carrying its cause. */
sealed class Failure : Exception() {
    class Transport(override val cause: Throwable) : Failure()
    class Request(val errors: GraphQLErrors) : Failure()
    class Malformed(val ingestError: IngestError) : Failure()
    class Environment(val environmentError: EnvironmentError) : Failure()

    /** The error a phase or a caller sees. */
    val error: Throwable
        get() = when (this) {
            is Transport -> cause
            is Request -> errors
            is Malformed -> ingestError
            is Environment -> environmentError
        }
}
