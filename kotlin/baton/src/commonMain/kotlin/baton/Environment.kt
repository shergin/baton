package baton

import androidx.compose.runtime.snapshots.ObserverHandle
import androidx.compose.runtime.snapshots.Snapshot
import kotlin.concurrent.atomics.AtomicBoolean
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.time.Duration
import kotlin.time.TimeSource
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Store plus transport plus configuration, in Relay's sense: one per backend
 * and app session. It holds the live side of the operations, their handles
 * with the fetches in flight; what keeps records alive is the store's. The
 * store belongs to the thread that made it, so the environment commits on
 * [mainDispatcher], which runs there, and tokenizes responses on
 * [ingestDispatcher]; a test passes one test dispatcher for both. Its
 * suspending calls run on [mainDispatcher] whatever thread calls them, as
 * the Swift environment's calls run on the main actor; its synchronous
 * calls are made on the store's thread. See `spec/runtime.md`, section 10.
 */
class Environment(
    val transport: Transport,
    /** The transport subscriptions go through, when one is given: a socket, or another that streams events. */
    val subscriptions: Transport? = null,
    /**
     * The store, made on the thread it will belong to; the environment owns
     * it from here on. An operation that states no `@cacheExpiration` takes
     * the store's, and its release buffer keeps released roots alive.
     */
    val store: Store = Store(),
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val ingestDispatcher: CoroutineDispatcher = Dispatchers.Default,
    /**
     * Whether the missing-data events are printed until a log is set, as a
     * debug build of the Swift runtime prints them. Common Kotlin has no
     * build configuration to read, so the app passes its own; the harness
     * passes true.
     */
    debug: Boolean = false,
) {
    /** Where the environment's fetches, and the collector's passes, run: on the store's thread, ended with the session. */
    internal val scope = CoroutineScope(SupervisorJob() + mainDispatcher)

    /**
     * Sends the snapshot system's apply notifications after the runtime's
     * own writes, which `snapshotFlow` and the other apply observers hear:
     * once per burst, posted to the main dispatcher behind the burst, as
     * Compose UI's frame clock sends them where a composition exists;
     * without one nothing would, and a model over `snapshotFlow` would never
     * see a change (`docs/recipes/views.md`). Compose UI's sending beside
     * this one finds nothing left to send. The main dispatcher is one that
     * posts, as the store's thread asks. Disposed at the end.
     */
    @OptIn(ExperimentalAtomicApi::class)
    private val applyScheduled = AtomicBoolean(false)

    @OptIn(ExperimentalAtomicApi::class)
    private val applyObserver: ObserverHandle = Snapshot.registerGlobalWriteObserver {
        if (applyScheduled.compareAndSet(expectedValue = false, newValue = true)) {
            mainDispatcher.dispatch(
                EmptyCoroutineContext,
                Runnable {
                    applyScheduled.store(false)
                    Snapshot.sendApplyNotifications()
                },
            )
        }
    }

    init {
        store.scheduler = { pass -> scope.launch { pass() } }
        if (debug && store.log == null) store.log = { event -> event.debugText?.let(::println) }
    }

    /**
     * What the runtime did and what went wrong, one `LogEvent` at a time, for
     * the app's own logging and metrics: names and counts, never a record or
     * a value. With `debug`, the missing-data events are printed until it is
     * set; null silences them.
     */
    var log: ((LogEvent) -> Unit)?
        get() = store.log
        set(value) {
            if (!ended) store.log = value
        }

    /** The handles, by the operation's key, for as long as their roots are the store's: equal operation values share one. */
    private val handles = HashMap<String, OperationHandle<*>>()

    /** The subscriptions' handles, by the operation's key, while retained, or made and not yet retained: equal operation values share one. */
    private val subscriptionHandles = HashMap<String, SubscriptionHandle<*>>()

    /** Whether the session has ended: every later call fails with `EnvironmentError.Gone`, and what is still held says so. */
    var ended: Boolean = false
        private set

    /**
     * Whether the app is active, set by the app from its lifecycle and by
     * hand in tests; true until set. While inactive every retained
     * subscription's stream is closed and its retention kept; activity opens
     * the streams again, each counted as a resumption. Queries read nothing
     * of it: `revalidate()` is the app's call on return.
     */
    var isActive: Boolean = true
        set(value) {
            if (field == value) return
            field = value
            if (ended) return
            for (handle in subscriptionHandles.values.toList()) {
                if (handle.retainCount == 0) continue
                if (value) handle.resume() else handle.park()
            }
        }

    /** The handle for an operation value, shared by every holder of an equal value. The policy is applied on every attach. */
    fun <Data : Lens> handle(operation: QueryOperation<Data>, fetchPolicy: FetchPolicy = FetchPolicy.Default): OperationHandle<Data> {
        store.checkThread()
        val key = Store.rootKey(operation.type.name, operation.variables)
        @Suppress("UNCHECKED_CAST")
        val handle = handles[key] as OperationHandle<Data>? ?: OperationHandle(operation, key, this).also {
            // A root until its first release; the caller retains it.
            if (!ended) handles[key] = it
        }
        handle.apply(fetchPolicy)
        return handle
    }

    /** The handle for a subscription value, shared by equal values; its first retention opens the stream, and its root lives while it is retained. */
    fun <Data : Lens> subscriptionHandle(operation: SubscriptionOperation<Data>): SubscriptionHandle<Data> {
        store.checkThread()
        val key = Store.rootKey(operation.type.name, operation.variables)
        @Suppress("UNCHECKED_CAST")
        (subscriptionHandles[key] as SubscriptionHandle<Data>?)?.let { return it }
        val handle = SubscriptionHandle(operation, key, this)
        if (!ended) subscriptionHandles[key] = handle
        return handle
    }

    /** Starts fetching before anything attaches; the root waits in the release buffer, and the first attach makes no request of its own. */
    fun <Data : Lens> preload(operation: QueryOperation<Data>, fetchPolicy: FetchPolicy = FetchPolicy.Default): OperationHandle<Data> {
        val handle = handle(operation, fetchPolicy)
        // Only a fetch the preload made can serve the first attach.
        handle.preloaded = handle.isFetching
        if (handle.retainCount == 0 && !ended) evict(store.park(handle.key))
        return handle
    }

    /** Marks every handle's data stale; retained handles whose holders allow the network refetch at once, the data visible until the response commits. */
    fun invalidate() {
        store.checkThread()
        if (ended) return
        store.invalidate()
        for (handle in handles.values.toList()) if (handle.retainCount > 0) handle.refetchIfStale()
    }

    /** Refetches the retained operations that are stale or whose last fetch failed, where a holder allows the network. Marks nothing. */
    fun revalidate() {
        store.checkThread()
        if (ended) return
        for (handle in handles.values.toList()) if (handle.retainCount > 0) handle.revalidate()
    }

    /**
     * Ends the session, once and for good: cancels every fetch the
     * environment started, drops the roots, clears every record, forgets
     * the session's keys, and closes the image once it has written what it
     * was handed. A handle still held reads failed with
     * `EnvironmentError.Gone` and tells its observers; a lens still held
     * finds its records cleared; every later call fails with the same
     * error, and a response that lands later reaches neither the store nor
     * the log.
     */
    suspend fun end() {
        withContext(mainDispatcher) {
            store.checkThread()
            if (ended) return@withContext
            ended = true
            for (handle in handles.values.toList()) handle.end()
            handles.clear()
            for (handle in subscriptionHandles.values.toList()) handle.end()
            subscriptionHandles.clear()
            // The image writes what it was handed, under the session's keys,
            // and gives its file back for the next environment before the store
            // forgets the keys. Nothing commits meanwhile: the environment has
            // ended.
            store.persistence?.close()
            store.end()
            scope.cancel()
            applyObserver.dispose()
        }
    }

    /**
     * Fetches an operation and commits the response; a handle of it, if any,
     * follows. An operation with `@throwOnFieldError` throws the field errors
     * its handle fails on; any other operation's field errors are read where
     * a lens reads them and logged as `fieldError` events.
     */
    suspend fun <Data : Lens> fetch(operation: QueryOperation<Data>) {
        withContext(mainDispatcher) {
            if (ended) throw EnvironmentError.Gone
            val type = operation.type
            val committed = fetch(type, operation.variables, store.resolve(type.plan, operation.variables), null)
            if (!type.throwsOnFieldError || ended) return@withContext
            // The handle's reading: the operation's own selection and the errors no field holds, read once and healed nowhere.
            val anchor = Anchor(store.root, Owner.reading(operation.variables, store))
            val errors = committed.unplaced + type.fieldErrors(anchor)
            if (errors.isNotEmpty()) throw FieldErrors(errors)
        }
    }

    /**
     * Fetches an operation by its type and variables and commits the
     * response: a refetch and a page run this way. No handle comes of it,
     * and the operation's root, dated by the commit, waits in the release
     * buffer if nothing retains it.
     */
    internal suspend fun fetch(type: OperationType<*>, variables: Variables) {
        if (ended) throw EnvironmentError.Gone
        fetch(type, variables, store.resolve(type.plan, variables), null)
    }

    /** Fetches a page of a connection: the loading flag on the connection record is set for the duration, and the commit merges the page. */
    internal suspend fun paginate(type: OperationType<*>, variables: Variables, connection: Record, loading: Slot) {
        if (ended) throw EnvironmentError.Gone
        store.local { batch -> store.set(connection, loading, Value.True, batch) }
        try {
            fetch(type, variables)
        } finally {
            if (!ended) store.local { batch -> store.set(connection, loading, Value.False, batch) }
        }
    }

    /**
     * Commits a payload for an operation that some other road delivered: a
     * REST response in the operation's shape, a socket's tick, a preview's
     * fixture, a test's seed. It is read by the operation's plan and
     * committed as a fetch's response is, at the root of the operation's
     * kind, and may carry part of what the operation selects. Under
     * `@throwOnFieldError` the field errors no `@catch` handled are thrown.
     */
    suspend fun commitPayload(operation: Operation<*>, payload: Payload) {
        withContext(mainDispatcher) {
            if (ended) throw EnvironmentError.Gone
            val type = operation.type
            val root = store.root(Store.rootKey(type.name, operation.variables), store.resolve(type.plan, operation.variables), store.root(type.kind))
            val committed = commit(payload.bytes, root.resolved, root, checkingCancellation = false, complete = false)
            if (type.throwsOnFieldError && committed.uncaught.isNotEmpty()) throw FieldErrors(committed.uncaught)
        }
    }

    /**
     * Commits a mutation and returns its data, which reads the mutation root.
     * The request and the commit run where the caller's cancellation does not
     * reach them: a server that received the mutation applied it. The data
     * stays alive until `releaseBufferSize` completions of other operation
     * values follow it. An optimistic response is read by the mutation's
     * plan and applied as a layer before the request, in the turn of the
     * call; the server's payload replaces the layer in one batch, and a
     * failure reverts it.
     */
    suspend fun <Data : Lens> mutate(operation: MutationOperation<Data>, optimistic: Payload? = null): Data = withContext(mainDispatcher) {
        if (ended) throw EnvironmentError.Gone
        val type = operation.type
        val resolved = store.resolve(type.plan, operation.variables)
        val root = store.root(Store.rootKey(type.name, operation.variables), resolved, store.mutationRoot)
        val layer = optimistic?.let { store.applyOptimistic(Ingest.normalize(it.bytes, resolved, Store.MUTATION_ROOT_KEY)) }
        val committed = try {
            withContext(NonCancellable) {
                val payload = transport.payload(request(type, operation.variables))
                commit(payload, resolved, root, checkingCancellation = false, replacing = layer)
            }
        } catch (error: Throwable) {
            if (layer != null && !ended) store.revertOptimistic(layer)
            throw error
        }
        store.keepCompleted(root)
        if (type.throwsOnFieldError && committed.uncaught.isNotEmpty()) throw FieldErrors(committed.uncaught)
        type.data(Anchor(store.mutationRoot, scope(root, operation.variables)))
    }

    /** What a commit left for the operation's reading besides its records: the field errors no `@catch` handled, and those no field holds. */
    internal class Committed(val uncaught: List<FieldError> = emptyList(), val unplaced: List<FieldError> = emptyList()) {
        operator fun plus(other: Committed): Committed = Committed(uncaught + other.uncaught, unplaced + other.unplaced)

        companion object {
            fun of(changes: ChangeSet): Committed = Committed(changes.uncaughtFieldErrors, changes.unplacedErrors)

            /** A part the server could not deliver: its errors count once each. */
            fun of(failure: Ingest.FailedPart): Committed = Committed(failure.uncaught, failure.changes.unplacedErrors)
        }
    }

    private fun request(type: OperationType<*>, variables: Variables): Request = Request(
        operationName = type.name,
        kind = type.kind,
        document = type.document,
        variables = variables,
        errorBehavior = type.errorBehavior,
        incremental = type.hasDeferred,
    )

    /**
     * Fetches with a plan already resolved, as a handle holds it, and logs
     * the fetch's events. The field errors are the caller's to weigh;
     * [firstPart] is handed what the first part of a deferred response
     * committed.
     */
    internal suspend fun fetch(
        type: OperationType<*>,
        variables: Variables,
        resolved: ResolvedSelection,
        firstPart: ((Committed) -> Unit)?,
    ): Committed {
        log(LogEvent.FetchStarted(type.name))
        val started = TimeSource.Monotonic.markNow()
        store.inFlight.add(resolved)
        try {
            val committed = send(type, variables, resolved, firstPart)
            for (error in committed.uncaught) log(LogEvent.FieldError(type.name, error.path))
            log(LogEvent.FetchCompleted(type.name, started.elapsedNow()))
            return committed
        } catch (error: Throwable) {
            log(LogEvent.FetchFailed(type.name, LogEvent.FailureKind.of(error)))
            throw error
        } finally {
            store.inFlight.remove(resolved)
        }
    }

    /**
     * The events of a subscription, as its transport delivers them: a flow
     * that fails with `EnvironmentError.NoSubscriptionTransport` when the
     * environment has none, and with `EnvironmentError.Gone` after the end.
     */
    internal fun subscribe(type: OperationType<*>, variables: Variables): Flow<ByteArray> {
        val subscriptions = subscriptions
        if (ended || subscriptions == null) {
            val failure = if (ended) EnvironmentError.Gone else EnvironmentError.NoSubscriptionTransport
            return flow { throw failure }
        }
        return subscriptions.send(request(type, variables))
    }

    /** Commits one event of a subscription through the door, at the subscription root; the door checks the stream's cancellation first. */
    internal suspend fun commitEvent(payload: ByteArray, root: Store.Root) {
        commit(payload, root.resolved, root)
    }

    /** Logs an event, unless the session has ended: a response that lands after the end reaches neither the store nor the log. */
    private fun log(event: LogEvent) {
        if (ended) return
        store.log?.invoke(event)
    }

    /** The fetch itself: the request sent, and the one payload or the parts of a deferred response committed. */
    private suspend fun send(type: OperationType<*>, variables: Variables, resolved: ResolvedSelection, firstPart: ((Committed) -> Unit)?): Committed {
        val request = request(type, variables)
        // The operation's root: a handle's, or one made here, which waits in the release buffer once dated if nothing retains it.
        val root = store.root(Store.rootKey(type.name, variables), resolved, store.root)
        if (!type.hasDeferred) {
            // The request is sent from the store's thread, as every transport call is; the response is awaited where it is
            // read, on the ingest dispatcher, so the store's thread is entered once, for the commit, and not first when the
            // bytes arrive, when it may be drawing a frame. A fetch superseded while its response was on the way or being
            // read must not land after the one that replaced it.
            val payloads = transport.send(request)
            val changes = withContext(ingestDispatcher) { Ingest.normalize(payloads.payload(request), resolved, root.record.key, complete = true) }
            currentCoroutineContext().ensureActive()
            return commit(changes, root)
        }
        var committed = Committed()
        val delivery = Delivery(store, resolved)
        var first = true
        transport.send(request).transformWhile<ByteArray, Unit> { part ->
            if (first) {
                first = false
                val opening = withContext(ingestDispatcher) { Ingest.normalizeFirstPart(part, resolved, Store.ROOT_KEY, complete = true) }
                currentCoroutineContext().ensureActive()
                committed += commit(opening.changes)
                delivery.announce(opening.pending)
                firstPart?.invoke(committed)
                return@transformWhile opening.hasNext
            }
            val incremental = withContext(ingestDispatcher) { Ingest.incremental(part) }
            delivery.announce(incremental.pending)
            val objects = delivery.objects(incremental)
            val failures = delivery.failures(incremental)
            val changes = withContext(ingestDispatcher) { objects.map { it.normalize() } }
            currentCoroutineContext().ensureActive()
            for (change in changes) committed += commit(change)
            for (failure in failures) {
                commit(failure.changes)
                committed += Committed.of(failure)
            }
            incremental.hasNext
        }.collect()
        // A deferred response is fetched, and fresh, once its stream completes.
        if (!ended) evict(store.date(root))
        return committed
    }

    /**
     * The one door from a payload to slots: the payload is read by the plan
     * on [ingestDispatcher] into a change set, which is committed on the
     * store's thread as a server batch at the root the operation hangs off.
     * A query's fetch checks for cancellation before the commit, so a
     * response superseded while it was read never lands; a mutation and a
     * payload committed by hand do not. [complete] says whether the payload
     * must answer every field the plan selects, as a server's response does.
     */
    private suspend fun commit(
        payload: ByteArray,
        plan: ResolvedSelection,
        root: Store.Root,
        checkingCancellation: Boolean = true,
        complete: Boolean = true,
        replacing: Store.OptimisticLayer? = null,
    ): Committed {
        val changes = withContext(ingestDispatcher) { Ingest.normalize(payload, plan, root.record.key, complete) }
        if (checkingCancellation) currentCoroutineContext().ensureActive()
        return commit(changes, root, complete, replacing)
    }

    /**
     * The door's lower half: a change set committed as a server batch, and
     * the root dated when the change set completes its operation's response.
     * The server's answer to an optimistic mutation replaces its layer in
     * the same batch. A response that lands after the end reaches nothing.
     */
    private fun commit(changes: ChangeSet, root: Store.Root? = null, complete: Boolean = true, replacing: Store.OptimisticLayer? = null): Committed {
        if (ended) return Committed()
        store.commit(changes, replacing)
        if (root != null) evict(store.date(root, complete))
        return Committed.of(changes)
    }

    /**
     * The heal: a read under [root] found data missing. The store marks the
     * root stale, and its handle refetches if a holder allows the network,
     * once per fetch of the root; a field still missing after the heal's own
     * refetch is reported as unexpected and healed no further. A lens with
     * no root is reported and not healed.
     */
    internal fun heal(root: Store.Root?, record: Record, slot: Slot) {
        if (root == null || ended) return
        if (!store.heal(root)) {
            store.log?.invoke(LogEvent.Unexpected(record.type.name, store.keys.text(slot)))
            return
        }
        handles[root.key]?.fetchForHeal()
    }

    /** A handle retained: it is among the environment's again if its root had left. */
    internal fun didRetain(handle: OperationHandle<*>) {
        if (ended) return
        if (handles[handle.key] == null) handles[handle.key] = handle
    }

    /** A subscription retained: it is among the environment's again if its last release had let it go. */
    internal fun didRetain(handle: SubscriptionHandle<*>) {
        if (ended) return
        if (subscriptionHandles[handle.key] == null) subscriptionHandles[handle.key] = handle
    }

    /** A subscription released to no holder: its stream closed and its root left the store at once. */
    internal fun didEnd(handle: SubscriptionHandle<*>) {
        if (subscriptionHandles[handle.key] === handle) subscriptionHandles.remove(handle.key)
    }

    /** Drops the handles of roots the store pushed out, with the fetches they had in flight. */
    internal fun evict(keys: List<String>) {
        for (key in keys) handles.remove(key)?.cancel()
    }

    /** The scope the lenses under [root] read in, made once per root: they fetch through this environment and are healed through the root. */
    internal fun scope(root: Store.Root, variables: Variables): Owner = root.scope ?: Owner(variables, store, this, root)

    /** A mutation action over this environment, as the composable for a mutation makes one. */
    internal fun <Op : MutationOperation<Data>, Data : Lens> action(): MutationAction<Op, Data> = MutationAction(this)
}
