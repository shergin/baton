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
enum class ErrorBehavior(val wire: String) { PROPAGATE("PROPAGATE"), NULL("NULL"), ABORT("ABORT") }

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
    val hasDeferred: Boolean get() = false
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
 * type that knows everything else about it. The host markers `@Query`,
 * `@Mutation` and `@Subscription` keep the short names; a generated value
 * implements `QueryOperation`, `MutationOperation` or `SubscriptionOperation`.
 */
interface Operation<Data : Lens> {
    val variables: Variables

    @Generated
    val type: OperationType<Data>
}

interface QueryOperation<Data : Lens> : Operation<Data> {
    /** Where the value stands: unresolved, resolved to its handle, or not injected. */
    @Generated
    var resolution: Resolution<OperationHandle<Data>>
}

interface MutationOperation<Data : Lens> : Operation<Data>

interface SubscriptionOperation<Data : Lens> : Operation<Data> {
    @Generated
    var resolution: Resolution<SubscriptionHandle<Data>>
}

/** An operation value's standing in a composable: declared only, resolved to its handle, or outside every environment. */
sealed interface Resolution<out Handle : Any> {
    /** The handle, when resolved. */
    val handle: Handle?

    data object Unresolved : Resolution<Nothing> {
        override val handle: Nothing? get() = null
    }

    data object NotInjected : Resolution<Nothing> {
        override val handle: Nothing? get() = null
    }

    data class Resolved<Handle : Any>(override val handle: Handle) : Resolution<Handle>
}

/**
 * What a query's data deserves: loading, ready with its lens, or failed with
 * the error that says why. Stable: a value never changes, a lens is stable,
 * and an error is compared as the same object, so a composable handed an
 * equal phase skips, a failed one among them.
 */
@Stable
sealed interface Phase<out Data> {
    data object Loading : Phase<Nothing>
    data class Ready<Data>(val data: Data) : Phase<Data>
    data class Failed(val error: Throwable) : Phase<Nothing>
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

/** Loading until resolved in a composable; failed with `EnvironmentError.NotInjected` outside every environment. */
val <Data : Lens> QueryOperation<Data>.phase: Phase<Data>
    get() = when (val resolution = resolution) {
        Resolution.Unresolved -> Phase.Loading
        Resolution.NotInjected -> Phase.Failed(EnvironmentError.NotInjected)
        is Resolution.Resolved -> resolution.handle.phase
    }

/** The last fetch: idle, in flight, or failed with its failure and when; idle where no environment could make one. */
val QueryOperation<*>.fetch: Fetch get() = resolution.handle?.fetch ?: Fetch.Idle

/** Whether a fetch is running while earlier data stays visible. */
val QueryOperation<*>.isRefreshing: Boolean get() = resolution.handle?.isRefreshing ?: false

/** Whether the data predates an invalidation or the cache expiration. */
val QueryOperation<*>.isStale: Boolean get() = resolution.handle?.isStale ?: false

/**
 * Fetches again and commits; the data stays visible meanwhile, and a failure
 * is thrown here rather than shown in place of it. Outside every environment
 * it throws `EnvironmentError.NotInjected`.
 */
suspend fun QueryOperation<*>.refetch() {
    when (val resolution = resolution) {
        Resolution.Unresolved -> return
        Resolution.NotInjected -> throw EnvironmentError.NotInjected
        is Resolution.Resolved -> resolution.handle.refetch()
    }
}

/** After a failure, fetches again: a failure with data behind it keeps the data visible meanwhile; any other shows loading. */
fun QueryOperation<*>.retry() {
    resolution.handle?.retry()
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
