package baton

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeMark
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async

/**
 * The live side of a query value: a view of its root, which is the store's
 * and holds whether the data is there and what it deserves, and of its
 * fetch, which is the environment's; its phase is derived from the two and
 * stored nowhere. Made by the environment, shared by equal operation values.
 * What a composable reads of it, the phase, the fetch and what they derive
 * from, is snapshot state, so the composable recomposes when they move. Used
 * on the store's thread. See `spec/runtime.md`, section 8.
 */
class OperationHandle<Data : Lens> internal constructor(
    val operation: QueryOperation<Data>,
    /** The operation's name and variables, which name its root. */
    internal val key: String,
    /** The environment that made the handle; a handle released after its end does nothing. */
    internal val environment: Environment,
) {
    private val type: OperationType<Data> = operation.type
    private val store: Store = environment.store

    /** The handle's root among the store's: what keeps its records alive. */
    internal val root: Store.Root = store.root(key, store.resolve(type.plan, operation.variables), store.root)

    /** The scope every lens of the handle reads in. */
    private val owner: Owner = environment.scope(root, operation.variables)

    /**
     * The last fetch, as a value: idle, in flight, or failed with its
     * failure and when it failed. A fetch that fails behind data leaves the
     * phase as it was and is read here, by every view of the handle.
     */
    var fetch: Fetch by mutableStateOf(Fetch.Idle)
        private set

    /** Whether the environment ended: the handle reads gone, whatever the store holds. */
    private var ended by mutableStateOf(false)

    /** Whether a `storeOnly` attach found the store without the data; the phase says so until the data comes or a fetch is started by hand. */
    internal var missingData by mutableStateOf(false)
        private set

    /** Whether a `networkOnly` attach by a view nobody shows the handle to waits for its own response: loading until it lands. */
    private var awaitsOwnResponse by mutableStateOf(false)

    /**
     * The field errors of the last fetch that no field in the store holds,
     * which `@throwOnFieldError` counts until the next fetch: the network's
     * fact, kept here and weighed with the root's verdict.
     */
    private var unplaced by mutableStateOf(emptyList<FieldError>())

    /** The fetch in flight; its value is the failure it ended with. */
    private var job: Deferred<Throwable?>? = null

    /** Set by a `preload` that fetched: the first attach finds the fetch made, or on the way. */
    internal var preloaded = false

    /** The policy of the last attach, which the retention it makes keeps. */
    private var lastPolicy = FetchPolicy.Default

    init {
        // An operation with a policy judges its root's data.
        if (type.throwsOnFieldError || type.bubbles) root.judge = Store.Judge { judge() }
    }

    /**
     * What the data deserves: generated code's walk of the operation's own
     * selection, as Relay's reader of the operation weighs it. The root asks
     * after a batch that changed what the verdict reads, and when the data
     * is found or fetched.
     */
    private fun judge(): Store.Verdict {
        if (type.throwsOnFieldError) {
            val errors = type.fieldErrors(anchor)
            if (errors.isNotEmpty()) return Store.Verdict.FieldErrors(errors)
        }
        if (type.bubbles) type.missingRequiredField(anchor)?.let { return Store.Verdict.RequiredMissing(it) }
        return Store.Verdict.Sound
    }

    /** When the store last committed the operation's response: the root's age. */
    val fetchTime: TimeMark? get() = root.fetchTime

    /** How many hold the handle's root; for the tests. */
    internal val retainCount: Int get() = root.holders

    /**
     * The phase, derived and never stored. With the data in the store it is
     * what the data deserves: the root's verdict, weighed with the errors the
     * last response carried that no field holds, read without the fetch, so
     * a fetch that changed nothing wakes no composable that reads the phase.
     * Without the data it is what the network did: loading, or the fetch's
     * failure. An ended environment reads gone whatever the store holds; a
     * `storeOnly` attach that found no data reads so until the data comes; a
     * `networkOnly` attach nobody shows waits for its own response.
     */
    val phase: Phase<Data>
        get() {
            if (ended) return Phase.Failed(EnvironmentError.Gone)
            if (!root.present || awaitsOwnResponse) {
                (fetch as? Fetch.Failed)?.let { return Phase.Failed(it.failure.error) }
                if (missingData) return Phase.Failed(MissingDataError(type.name))
                return Phase.Loading
            }
            if (type.throwsOnFieldError) {
                val errors = unplaced + ((root.verdict as? Store.Verdict.FieldErrors)?.errors ?: emptyList())
                if (errors.isNotEmpty()) return Phase.Failed(FieldErrors(errors))
            }
            if (type.bubbles) {
                (root.verdict as? Store.Verdict.RequiredMissing)?.let { return Phase.Failed(RequiredFieldError(it.path, type.name)) }
            }
            return Phase.Ready(data)
        }

    /** Whether a fetch is in flight. */
    internal val isFetching: Boolean get() = job != null

    /** Whether a fetch is running while earlier data stays visible: data present and a fetch in flight. */
    val isRefreshing: Boolean get() = fetch == Fetch.InFlight && showsData

    /** Whether the phase shows data: the store holds it and the handle shows it, ready or failed on what the data deserves. */
    private val showsData: Boolean get() = root.present && !awaitsOwnResponse && !ended

    private val anchor: Anchor get() = Anchor(store.root, owner)

    private val data: Data get() = type.data(anchor)

    /**
     * Whether the data predates `Environment.invalidate()` or is older than
     * the operation's expiration, `@cacheExpiration(seconds:)`, or the
     * store's default when it states none. A handle with nothing to show has
     * nothing to go stale; one failed on field errors or a `@required` null
     * has its data in the store, and it ages as ready data does.
     */
    val isStale: Boolean
        get() {
            if (!showsData) return false
            return store.isStale(root, type.cacheExpirationSeconds?.seconds)
        }

    /** Applies a policy on attach: shows what the store allows, fetches when the policy asks for it. */
    internal fun apply(policy: FetchPolicy) {
        lastPolicy = policy
        // A preload's fetch is the first attach's: in flight, or done with
        // data that is still fresh, it is not made again.
        if (preloaded) {
            preloaded = false
            if (job != null) return
            if (root.present && !isStale) {
                root.found()
                return
            }
        }
        if (policy == FetchPolicy.NETWORK_ONLY) {
            // What the store holds is not asked; a handle no one shows yet waits for its own response.
            if (retainCount == 0) awaitsOwnResponse = true
            fetchUnlessInFlight()
            return
        }
        val answer = store.check(root.resolved)
        val complete = answer != Answer.MISS
        // The deferred parts the store holds half are cleared and fetched; the initial part shows meanwhile.
        val partial = complete && type.hasDeferred && !store.deferredPartsHold(root.resolved)
        if (complete) {
            // Data an earlier launch fetched takes the age the image knows.
            store.takeAge(root, hydrated = answer == Answer.IMAGE)
            // The data is there, and its verdict is settled on it: a parked handle saw no commit.
            root.found()
        }
        when (policy) {
            FetchPolicy.STORE_ONLY -> if (!complete && !root.present) missingData = true
            FetchPolicy.STORE_OR_NETWORK -> {
                // An error the last response carried with no field to hold it is in no record a commit could clear.
                val failsUnplaced = type.throwsOnFieldError && unplaced.isNotEmpty()
                if (!complete || partial || isStale || failsUnplaced) fetchUnlessInFlight()
            }
            FetchPolicy.STORE_AND_NETWORK, FetchPolicy.NETWORK_ONLY -> fetchUnlessInFlight()
        }
    }

    /** Starts a fetch unless one is in flight. */
    internal fun fetchUnlessInFlight() {
        if (job != null) return
        start()
    }

    /** Starts a fetch, superseding the one in flight. */
    private fun start() {
        job?.let { superseded ->
            job = null
            superseded.cancel()
        }
        // A fetch started by hand on a `storeOnly` handle supersedes what the attach found missing.
        missingData = false
        if (ended || environment.ended) {
            // Nothing can fetch for a handle whose environment ended: without data the phase reads the failure.
            fetch = Fetch.Failed(Failure.Environment(EnvironmentError.Gone), store.now)
            return
        }
        fetch = Fetch.InFlight
        lateinit var current: Deferred<Throwable?>
        current = environment.scope.async(start = CoroutineStart.LAZY) { run(current) }
        job = current
        current.start()
    }

    /**
     * The fetch itself, its outcome recorded unless a later fetch, an
     * eviction or the end took the handle over: their state is theirs.
     * Returns what a `refetch` throws.
     */
    private suspend fun run(current: Deferred<Throwable?>): Throwable? {
        var failure: Throwable? = null
        try {
            val committed = environment.fetch(type, operation.variables, root.resolved) { first ->
                // A deferred response shows its first part at once; it is fetched, and fresh, once the stream completes.
                if (job === current) {
                    unplaced = first.unplaced
                    awaitsOwnResponse = false
                    root.committed()
                }
            }
            if (job === current) unplaced = committed.unplaced
        } catch (cancellation: CancellationException) {
            if (job !== current) return null
            // The transport cancelled its own work: nothing to show.
            job = null
            fetch = Fetch.Idle
            return null
        } catch (error: Throwable) {
            failure = error
        }
        if (job !== current) return null
        job = null
        if (failure == null) {
            // The door dated the root and made its data present.
            fetch = Fetch.Idle
            awaitsOwnResponse = false
            // A response whose field errors fail the operation fails its refetch the same way.
            return (phase as? Phase.Failed)?.error
        }
        // Data behind the failure stays visible; with nothing to show, the phase reads the failure.
        fetch = Fetch.Failed(Failure.of(failure), store.now)
        return failure
    }

    /**
     * Fetches again and waits for the result; the data stays visible
     * meanwhile, and a failure is thrown rather than shown in its place. A
     * refetch that a later fetch superseded returns without one; after the
     * environment's end it throws `EnvironmentError.Gone`.
     */
    suspend fun refetch() {
        if (ended || environment.ended) throw EnvironmentError.Gone
        start()
        val current = job ?: return
        current.join()
        if (current.isCancelled) return
        current.await()?.let { throw it }
    }

    /** Waits for the fetch in flight, if any; for the tests. */
    internal suspend fun settle() {
        job?.join()
    }

    /**
     * After a failure, fetches again. A failure with data behind it stays in
     * place, its data visible, and the fetch refreshes behind it as
     * `refetch()` does; any other shows loading meanwhile, since the fetch in
     * flight is what the phase reads without data.
     */
    fun retry() {
        start()
    }

    /**
     * Keeps the operation's records alive until the hold is released.
     * A composable holds one for its life; a class holds one in a property
     * and releases it when it is done.
     */
    fun retain(): Hold {
        val allowsNetwork = lastPolicy != FetchPolicy.STORE_ONLY
        store.retain(root, allowsNetwork)
        environment.didRetain(this)
        return Hold { release(allowsNetwork) }
    }

    /** A hold ended. At no holder the root enters the release buffer, and the handles of the roots it pushes out go with their fetches. */
    private fun release(allowingNetwork: Boolean) {
        environment.evict(store.release(root, allowingNetwork))
    }

    /** A fetch the runtime starts asks whether a holder allows the network: a `storeOnly` holder is fetched for by neither an invalidation nor a revalidation nor a heal. */
    internal fun refetchIfStale() {
        if (isStale && root.allowsNetwork) fetchUnlessInFlight()
    }

    /** Fetches again when the data is stale or the last fetch failed, if a holder allows the network. */
    internal fun revalidate() {
        if (!root.allowsNetwork) return
        if (isStale) fetchUnlessInFlight()
        if (fetch is Fetch.Failed) fetchUnlessInFlight()
    }

    /** Fetches again for a heal, unless a fetch is in flight. */
    internal fun fetchForHeal() {
        if (root.allowsNetwork) fetchUnlessInFlight()
    }

    /** Drops the fetch in flight: the root left, or the environment ended. */
    internal fun cancel() {
        val current = job
        job = null
        current?.cancel()
        fetch = Fetch.Idle
    }

    /** The environment ended: the fetch in flight is cancelled and the phase says gone to its observers. */
    internal fun end() {
        cancel()
        fetch = Fetch.Failed(Failure.Environment(EnvironmentError.Gone), store.now)
        ended = true
    }
}

/**
 * What keeps an operation's records alive: the token `retain()` returns,
 * whose release ends the hold. Kotlin has no deinit to end it, so the holder
 * releases it: a composable when it leaves, a class when it is done.
 * Releasing twice is releasing once. Used on the store's thread. Swift's
 * `Retention`; the Kotlin name is `Hold` so that `import baton.*` does not
 * hide `kotlin.annotation.Retention`.
 */
class Hold internal constructor(private val onRelease: () -> Unit) {
    private var released = false

    /** Ends the hold: at no holder the root waits in the release buffer. */
    fun release() {
        if (released) return
        released = true
        onRelease()
    }
}
