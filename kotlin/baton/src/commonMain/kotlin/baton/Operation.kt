package baton

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import kotlin.time.TimeMark

/** The text the compiler printed, or the id it was registered under; never both. */
sealed interface Document {
    data class Text(val text: String) : Document
    data class Id(val id: String) : Document
}

/** Which root an operation's response is committed under. */
enum class OperationKind { QUERY, MUTATION, SUBSCRIPTION }

/** The `onError` value a request carries when `baton.json` names one. */
enum class ErrorBehavior(val wire: String) { PROPAGATE("PROPAGATE"), NULL("NULL"), HALT("HALT") }

/** When a query's data comes from the store and when from the network. */
enum class FetchPolicy {
    /** The store if it has the data, the network otherwise. */
    STORE_OR_NETWORK,
    /** The store at once and the network as well. */
    STORE_AND_NETWORK,
    /** The network only; the store's data is not shown first. */
    NETWORK_ONLY,
    /** The store only; missing data is a failure. */
    STORE_ONLY;

    companion object {
        val Default: FetchPolicy = STORE_OR_NETWORK
    }
}

/**
 * What the build knows about an operation, held by the generated class's
 * companion: its name, document, kind and plan, and the flags its directives
 * set. One per operation, shared by every value of it. An application
 * passes a companion, as `rememberMutation(RenameMutation)` does, so the
 * interface is application API; what generated code alone calls is marked.
 */
interface OperationType<Data : Lens> {
    val name: String
    val document: Document
    val kind: OperationKind

    @Generated
    val plan: Plan
    val throwsOnFieldError: Boolean get() = false
    val bubbles: Boolean get() = false
    /** Whether the response may arrive in parts: a deferred fragment or a streamed list in it. */
    val hasIncremental: Boolean get() = false
    val errorBehavior: ErrorBehavior? get() = null
    val cacheExpirationSeconds: Double? get() = null

    /** The text a request carries, when the document is text. */
    val text: String? get() = (document as? Document.Text)?.text

    /** The root's lens over [anchor]. */
    @Generated
    fun data(anchor: Anchor): Data

    /** The uncaught field errors in the operation's own selection, which `@throwOnFieldError` fails on; none without it. */
    @Generated
    fun fieldErrors(anchor: Anchor): List<FieldError> = emptyList()

    /** The path of the first `@required` field that is null and bubbles to the root; none when every one is present. */
    @Generated
    fun missingRequiredField(anchor: Anchor): String? = null
}

/**
 * A query's type, naming the operation's class beside its data, so a call
 * that takes the companion infers both.
 */
interface QueryType<Op : QueryOperation<Data>, Data : Lens> : OperationType<Data>

/**
 * A mutation's type, naming the operation's class beside its data, so
 * `rememberMutation(RenameMutation)` infers its action's type.
 */
interface MutationType<Op : MutationOperation<Data>, Data : Lens> : OperationType<Data>

/**
 * A subscription's type, naming the operation's class beside its data, so a
 * call that takes the companion infers both.
 */
interface SubscriptionType<Op : SubscriptionOperation<Data>, Data : Lens> : OperationType<Data>

/**
 * An operation value: the variables it is run with, equal by them, and the
 * type that knows everything else about it. It carries nothing of the live
 * side, which the handle holds, so a generated value is immutable and a
 * composable is handed the same one for as long as its variables are the
 * same. The host markers `@Query`, `@Mutation` and `@Subscription` keep the
 * short names; a generated value implements `QueryOperation`,
 * `MutationOperation` or `SubscriptionOperation`.
 */
interface Operation<Data : Lens> {
    val variables: Variables

    @Generated
    val type: OperationType<Data>
}

/** A query's value: `rememberQuery` resolves it to its handle in a composition, `Environment.handle` outside one. */
interface QueryOperation<Data : Lens> : Operation<Data>

/** A mutation's value, committed through its action or `Environment.mutate`. */
interface MutationOperation<Data : Lens> : Operation<Data>

/** A subscription's value: `rememberSubscription` opens its stream in a composition, `Environment.subscriptionHandle` outside one. */
interface SubscriptionOperation<Data : Lens> : Operation<Data>

/**
 * What a query's data deserves: loading, ready with its lens, or failed with
 * the error that says why. Stable: a value never changes, a lens is equal
 * by its anchor, and a failure is equal by what it holds, so a composable
 * handed an equal phase skips, a failed one among them.
 */
@Stable
sealed interface Phase<out Data> {
    data object Loading : Phase<Nothing>
    data class Ready<Data>(val data: Data) : Phase<Data>

    /** No data to show, or data that fails the operation's own directives, for one of a closed set of reasons. */
    data class Failed(val failure: PhaseFailure) : Phase<Nothing> {
        /** The error as thrown or made: the transport's, the server's or the runtime's own, for a message or a cast. */
        val error: Throwable get() = failure.error
    }
}

/**
 * Why a resolved operation's phase is failed: a closed set, so a composable
 * branches on it without a cast. The fetch's kind carries the fetch's
 * [Failure] whole, so the kind the failure says survives to the composable
 * that reads the phase; the two data kinds are what the operation's
 * directives make of data that is in the store; missing data is a
 * `STORE_ONLY` attach the store could not answer. A composable outside every
 * environment, and a handle whose environment ended, read the fetch's
 * environment kind, since nothing could send a request. A `Throwable`, so a
 * `refetch` throws it; each kind a data class, so two readings of one
 * unchanged phase are equal.
 */
sealed class PhaseFailure : Exception() {
    /** The network did not deliver, or nothing could send: the fetch's failure, with its kind. */
    data class Fetch(val failure: Failure) : PhaseFailure()

    /** `@throwOnFieldError`: uncaught field errors in the operation's own selection, or carried by the last response with no field to hold them. */
    data class FieldErrors(val errors: baton.FieldErrors) : PhaseFailure()

    /** A `@required` field that is null and bubbled to the operation's root. */
    data class RequiredField(val requiredFieldError: RequiredFieldError) : PhaseFailure()

    /** A `STORE_ONLY` attach whose data the store does not have. */
    data class MissingData(val missingDataError: MissingDataError) : PhaseFailure()

    /** The error as thrown or made: the transport's, the server's or the runtime's own. */
    val error: Throwable
        get() = when (this) {
            is Fetch -> failure.error
            is FieldErrors -> errors
            is RequiredField -> requiredFieldError
            is MissingData -> missingDataError
        }

    override val message: String get() = error.message ?: error.toString()
}

/**
 * The last fetch of a handle, as a value read beside the phase: idle, in
 * flight, or failed with its failure and when it failed. Not a phase: the
 * phase is what the data deserves and the fetch is what the network did, so
 * a fetch that fails behind data is read here while the phase stays ready.
 * The handle's next response replaces it. Stable as the phase is.
 */
@Stable
sealed interface Fetch {
    /** The failure, when the last fetch failed. */
    val failure: Failure? get() = null

    data object Idle : Fetch
    data object InFlight : Fetch
    data class Failed(override val failure: Failure, val at: TimeMark) : Fetch
}

/**
 * A query's state in a composition, as `rememberQuery` returns it: the value
 * it was given and the handle it resolved the value to in the environment
 * `LocalBaton` provides, or no handle outside every provider. What it reads
 * of the handle is snapshot state, so a composable that reads the phase, the
 * fetch or the staleness recomposes when they move. Stable: one per value,
 * environment and policy, remembered for the composable's life.
 */
@Stable
class QueryState<Op : QueryOperation<Data>, Data : Lens> internal constructor(
    val operation: Op,
    /** The handle, shared by every holder of an equal value; null outside every environment. */
    val handle: OperationHandle<Data>?,
) {
    /** Loading, ready with its lens, or failed with the failure that says why; failed with the fetch's environment kind, not injected, outside every environment. */
    val phase: Phase<Data> get() = handle?.phase ?: NOT_INJECTED

    /** The last fetch: idle, in flight, or failed with its failure and when; idle where no environment could make one. */
    val fetch: Fetch get() = handle?.fetch ?: Fetch.Idle

    /** Whether a fetch is running while earlier data stays visible. */
    val isRefreshing: Boolean get() = handle?.isRefreshing ?: false

    /** Whether the data predates an invalidation or the cache expiration. */
    val isStale: Boolean get() = handle?.isStale ?: false

    /**
     * Fetches again and commits; the data stays visible meanwhile, and the
     * [PhaseFailure] the phase would show is thrown here instead. Outside
     * every environment it throws the fetch's environment kind, not injected.
     */
    suspend fun refetch() {
        (handle ?: throw PhaseFailure.Fetch(Failure.Environment(EnvironmentError.NotInjected))).refetch()
    }

    /** After a failure, fetches again: a failure with data behind it keeps the data visible meanwhile; any other shows loading. */
    fun retry() {
        handle?.retry()
    }

    private companion object {
        val NOT_INJECTED: Phase<Nothing> = Phase.Failed(PhaseFailure.Fetch(Failure.Environment(EnvironmentError.NotInjected)))
    }
}

/**
 * A mutation as a callable value: generated code gives it an `invoke` with
 * one argument per variable and an optional optimistic response, which
 * commits the mutation through the environment and returns its data. An
 * action outside every environment throws `EnvironmentError.NotInjected`
 * rather than commit into a store that stands in. Stable: equal as the same
 * object, and whether it is in flight is snapshot state.
 */
@Stable
class MutationAction<Op : MutationOperation<Data>, Data : Lens> internal constructor(private val environment: Environment?) {
    private var inFlight by mutableIntStateOf(0)

    /** Whether a commit of this mutation is in flight. */
    val isInFlight: Boolean get() = inFlight > 0

    /** Commits [operation], an optimistic response's payload applied first when given, and returns the mutation's data. */
    @Generated
    suspend fun commit(operation: Op, optimistic: Payload? = null): Data {
        val environment = environment ?: throw EnvironmentError.NotInjected
        inFlight += 1
        try {
            return environment.mutate(operation, optimistic)
        } finally {
            inFlight -= 1
        }
    }
}
