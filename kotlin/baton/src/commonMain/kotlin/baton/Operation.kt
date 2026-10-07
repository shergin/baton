package baton

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
 * set. One per operation, shared by every value of it.
 */
@Generated
interface OperationType<Data : Lens> {
    val name: String
    val document: Document
    val kind: OperationKind
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
}

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

/** What a query's data deserves: loading, ready with its lens, or failed with the error that says why. */
sealed interface Phase<out Data> {
    data object Loading : Phase<Nothing>
    data class Ready<Data>(val data: Data) : Phase<Data>
    data class Failed(val error: Throwable) : Phase<Nothing>
}

/** A query's handle: the operation's data in the store, observed in composition. Defined with the environment. */
class OperationHandle<Data : Lens> internal constructor()

/** A subscription's handle: its events, its latest data and its stream. Defined with the environment. */
class SubscriptionHandle<Data : Lens> internal constructor()
