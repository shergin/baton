package baton

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeMark
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The stream a subscription handle holds, as a value read beside its events:
 * not started, or parked while the environment is inactive; connecting until
 * the first event; open; waiting to reconnect after a failure, until the
 * instant it tries again; or ended, by the server's completion, by a request
 * error or an environment failure, or by the environment's end. Not a phase: a subscription has no data
 * of its own to wait for, so it has no loading. See `spec/runtime.md`,
 * section 8.
 */
sealed interface Stream {
    /** Whether the stream is connecting or open. */
    val isActive: Boolean get() = this == Connecting || this == Open

    data object Idle : Stream
    data object Connecting : Stream
    data object Open : Stream

    /** A failure ended the stream, read in the handle's `error`, and the handle opens it again at [until], by its fixed backoff. */
    data class Waiting(val until: TimeMark) : Stream

    /** The server completed the stream ([failure] null), or a failure ended it for good: a request error, an environment failure, a handle no longer retained, or the environment's end. */
    data class Ended(val failure: Failure?) : Stream
}

/**
 * The backoff before a failed stream is opened again: a step that doubles
 * from one second to thirty, jittered to between half and the whole of it,
 * reset by an event. Fixed, as `docs/decisions/subscriptions-reconnect-in-the-handle.md`
 * records; the base is a knob for the tests alone.
 */
internal object SubscriptionBackoff {
    var base: Duration = 1.seconds
    private val cap: Duration = 30.seconds

    fun delay(attempt: Int): Duration {
        val step = minOf(base * (1 shl minOf(attempt, 10)), cap)
        return step / 2 + step / 2 * Random.nextDouble()
    }
}

/**
 * The live side of a subscription value: the stream it holds open, how many
 * events arrived, the latest event's data and the error that ended the
 * stream. Each event is read by the operation's plan at the subscription
 * root and committed through the environment's one door, so its entities
 * merge and its edge directives apply. Made by the environment, shared by
 * equal operation values; what a composable reads of it is snapshot state.
 * Used on the store's thread. See `spec/runtime.md`, section 8.
 */
class SubscriptionHandle<Data : Lens> internal constructor(
    val operation: SubscriptionOperation<Data>,
    /** The operation's name and variables, which name its root. */
    internal val key: String,
    /** The environment that made the handle. */
    private val environment: Environment,
) {
    private val type: OperationType<Data> = operation.type
    private val store: Store = environment.store

    /** The handle's root among the store's, while retained. */
    internal val root: Store.Root = store.root(key, store.resolve(type.plan, operation.variables), store.subscriptionRoot)

    /** The scope every event's lens reads in. */
    private val owner: Owner = environment.scope(root, operation.variables)

    /** How many events have been committed. */
    var events: Int by mutableIntStateOf(0)
        private set

    /** The latest event, as a lens over the subscription root. */
    var latest: Data? by mutableStateOf(null)
        private set

    /** The error of the last event, cleared by the next good one, or the error that ended the stream. */
    var error: Throwable? by mutableStateOf(null)
        private set

    /** The stream, as a value: idle, connecting, open, waiting to reconnect, or ended. */
    var stream: Stream by mutableStateOf(Stream.Idle)
        private set

    /** Whether the stream is connecting or open. */
    val isActive: Boolean get() = stream.isActive

    /**
     * How many times the stream was opened again after it had been open or
     * had failed: after a failure's backoff, or after the environment was
     * inactive. Events may have been missed across each; an owner that
     * observes the count refetches its baseline.
     */
    var resumptions: Int by mutableIntStateOf(0)
        private set

    /** Whether the environment's inactivity closed the stream while the handle stayed retained, so activity opens it again. */
    private var parked = false

    /** The stream's work, while it runs. */
    private var job: Job? = null

    /** How many hold the stream open. */
    internal val retainCount: Int get() = root.holders

    /** Opens the stream unless it is open, or the environment has ended. */
    internal fun start() {
        if (job != null || environment.ended) return
        // Retained while the environment is inactive: the stream waits parked for activity, as one closed by inactivity does.
        if (!environment.isActive) {
            parked = true
            stream = Stream.Idle
            return
        }
        parked = false
        stream = Stream.Connecting
        error = null
        lateinit var current: Job
        current = environment.scope.launch(start = CoroutineStart.LAZY) { run(current) }
        job = current
        current.start()
    }

    /**
     * The stream's work: each connection's events committed, and a failure
     * while the handle is retained waited out by the backoff and the stream
     * opened again. A job a release, a park, a retry or the end replaced
     * leaves the state to whoever replaced it.
     */
    private suspend fun run(current: Job) {
        var attempt = 0
        while (true) {
            // How the stream ended, written once the job is known to be the handle's still.
            var ending: Stream = Stream.Ended(null)
            var failed = false
            try {
                environment.subscribe(type, operation.variables).collect { payload ->
                    try {
                        // The door checks the job's cancellation before the commit: a stream commits until its job ends.
                        environment.commitEvent(payload, root)
                        events += 1
                        latest = type.data(Anchor(store.subscriptionRoot, owner))
                        error = null
                        stream = Stream.Open
                        attempt = 0
                    } catch (failure: GraphQLErrors) {
                        // An event with errors and no data is one bad event; the stream goes on.
                        currentCoroutineContext().ensureActive()
                        error = failure
                    }
                }
            } catch (cancellation: CancellationException) {
                // The handle cancelled its own job; a transport that cancelled its own work ended the stream with nothing to show.
                if (!currentCoroutineContext().isActive) throw cancellation
            } catch (failure: Throwable) {
                if (job !== current) return
                error = failure
                ending = Stream.Ended(Failure.of(failure))
                failed = true
            }
            if (job !== current) return
            // A failure while the handle is retained is a wait, not an end. The server's completion ends the stream, and so
            // do a request error, the server's refusal of the operation as written, and an environment failure, such as a
            // missing subscription transport the environment cannot gain after its creation. The backoff would only repeat
            // either; a retry may try.
            val final = (ending as? Stream.Ended)?.failure.let { it is Failure.Request || it is Failure.Environment }
            if (!failed || final || retainCount == 0 || environment.ended) {
                job = null
                stream = ending
                return
            }
            // Failed while the environment is inactive: parked, so that activity opens the stream again rather than the backoff.
            if (!environment.isActive) {
                job = null
                parked = true
                stream = Stream.Idle
                return
            }
            val wait = SubscriptionBackoff.delay(attempt)
            attempt += 1
            stream = Stream.Waiting(store.now + wait)
            // A release, a park, a retry or the end cancels the wait and sets the state.
            delay(wait)
            if (job !== current) return
            if (retainCount == 0) {
                job = null
                stream = Stream.Idle
                return
            }
            resumptions += 1
            stream = Stream.Connecting
            error = null
        }
    }

    /** The environment went inactive: the stream closes while the handle stays retained, and activity opens it again. */
    internal fun park() {
        val current = job ?: return
        job = null
        current.cancel()
        parked = true
        stream = Stream.Idle
    }

    /** The environment is active again: a stream parked by its inactivity is opened again, counted as a resumption. */
    internal fun resume() {
        if (!parked || retainCount == 0 || job != null) return
        resumptions += 1
        start()
    }

    /** Opens the stream again after it ended, by an error or the server's completion, or while it waits, as long as the handle is retained. */
    fun retry() {
        if (retainCount == 0) return
        cancel()
        start()
    }

    /**
     * Keeps the stream open and the latest event's records alive until the
     * hold is released; the first hold opens the stream.
     */
    fun retain(): Hold {
        store.retain(root, allowingNetwork = true)
        environment.didRetain(this)
        start()
        return Hold { release() }
    }

    /** A hold ended. At no holder the stream closes and the root leaves at once; nothing is buffered. */
    private fun release() {
        store.release(root, allowingNetwork = true, buffering = false)
        if (root.holders > 0) return
        cancel()
        environment.didEnd(this)
    }

    /** The environment ended: the stream closes and says so. */
    internal fun end() {
        cancel()
        error = EnvironmentError.Gone
        stream = Stream.Ended(Failure.Environment(EnvironmentError.Gone))
    }

    /** Closes the stream; the state reads idle until it opens again. */
    private fun cancel() {
        val current = job
        job = null
        current?.cancel()
        stream = Stream.Idle
    }
}

/** The live side of a subscription value, which the composable that resolved it holds; null outside a composable, and outside every environment. */
val <Data : Lens> SubscriptionOperation<Data>.subscription: SubscriptionHandle<Data>? get() = resolution.handle
