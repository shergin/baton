package baton

import androidx.compose.runtime.snapshots.ObserverHandle
import androidx.compose.runtime.snapshots.Snapshot
import baton.spec.DateTimes
import baton.spec.Decimals
import baton.spec.Urls
import baton.testing.ScriptedTransport
import java.math.BigDecimal
import java.net.URI
import java.time.Instant
import java.util.IdentityHashMap
import kotlin.reflect.KClass
import kotlin.reflect.KParameter
import kotlin.reflect.KType
import kotlin.reflect.full.companionObjectInstance
import kotlin.reflect.full.functions
import kotlin.reflect.full.isSubclassOf
import kotlin.reflect.full.primaryConstructor
import kotlin.test.Test
import kotlin.test.fail
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * The second kind of fixture: each script of `spec/manifest.json`, run step
 * by step in one environment over one store, through a scripted transport
 * the steps answer, under a test dispatcher that is both the environment's
 * main dispatcher and its ingest dispatcher. After each step the store, the
 * handles, the log and the transport are compared with what the script
 * says, as `swift/Tests/BatonTests/ScriptTests.swift` compares them.
 *
 * A step this runtime cannot run yet stops its script, reported as pending
 * rather than failed: the image's (`relaunch`, a check answered from the
 * image), the subscriptions' (`event`, `active`, a subscription's handle, a
 * stream), and the steps named in [pending], which wait for the optimistic
 * layers and pagination. A step before it that fails fails the test.
 */
class ScriptTests {
    @Test
    fun `a script's steps leave the store, the handles and the log as the script says after each step`() {
        val failures = ArrayList<String>()
        val stops = ArrayList<String>()
        for (path in Script.paths) {
            val script = Script.load(path)
            if (path != "scripts/${script.name}.json") failures.add("$path: a script is named for its file, not ${script.name}")
            val run = ScriptRun(script, pending[script.name])
            try {
                runTest(timeout = 60.seconds) { run.run(this) }
            } catch (error: Throwable) {
                failures.add("${run.context}threw $error")
            }
            failures.addAll(run.failures)
            run.stopped?.let { stops.add(it) }
        }
        if (stops.isNotEmpty()) println("Scripts pending:\n" + stops.joinToString("\n"))
        if (failures.isNotEmpty()) fail("${failures.size} expectations differ:\n" + failures.joinToString("\n"))
    }

    private companion object {
        /** The steps that stop a script until a later milestone, by the script's name: the step's index and why. */
        val pending: Map<String, Pair<Int, String>> = mapOf(
            "optimistic" to (2 to "optimistic layers, which rebase under a server's commit, are the next milestone"),
        )
    }
}

/** One run of a script: the environment it runs in, the transport the steps answer through, and what the steps named. */
@OptIn(ExperimentalCoroutinesApi::class)
internal class ScriptRun(private val script: Script, private val pending: Pair<Int, String>?) {
    /** Holds every query and mutation until a step answers it, and lets the steps drive every deferred response. */
    private val transport = ScriptedTransport()
    private val heard = ArrayList<LogEvent>()
    private lateinit var scope: TestScope
    private lateinit var environment: Environment
    private val handles = HashMap<String, Live>()
    private val layers = HashMap<String, Layer>()
    /** The last check's answer. */
    private var answer: Answer? = null

    /** Where the run is, for the messages. */
    var context = "${script.name}: "
        private set
    val failures = ArrayList<String>()
    /** Why the script stopped before its end, when it did. */
    var stopped: String? = null
        private set

    private val store: Store get() = environment.store

    /** A query's handle a step named, and the retention its attach made. */
    private class Live(val operation: Bound, val handle: OperationHandle<*>, var retention: Retention?)

    /** A mutation in flight under its optimistic response. */
    private class Layer(val operation: Bound, val task: Deferred<Throwable?>)

    /** An operation value a step named, as the generated class the compiler made of its document. */
    private class Bound(val value: Operation<*>) {
        val type: OperationType<*> = value.type
        val name: String get() = type.name
        val variables: Variables get() = value.variables

        /** Whether a request is one of this operation value. */
        fun sent(request: Request): Boolean = request.operationName == name && request.variables == variables
    }

    private fun fail(message: String) {
        failures.add(context + message)
    }

    suspend fun run(scope: TestScope) {
        this.scope = scope
        val dispatcher = StandardTestDispatcher(scope.testScheduler)
        val store = Store(script.expiration?.seconds, script.buffer)
        environment = Environment(transport, transport, store, dispatcher, dispatcher)
        environment.log = { heard.add(it) }
        for ((index, step) in script.steps.withIndex()) {
            context = "${script.name}, step $index (${step.action.kind}): "
            val stop = stop(index, step)
            if (stop != null) {
                stopped = "${script.name}: pending at step $index (${step.action.kind}): $stop"
                break
            }
            heard.clear()
            Snapshot.sendApplyNotifications()
            val notified = if (step.notified == null) null else observeEverySlot()
            val sentBefore = transport.requestCount
            val thrown = perform(step.action)
            // A pass a step scheduled runs on a later turn of the main dispatcher.
            scope.runCurrent()
            check(step, thrown, notified, sentBefore)
        }
        environment.end()
        // A mutation the script left waiting runs where no cancellation reaches it: the transport lets it go.
        for (held in transport.held) held.refuse(TransportError(0, "the script ended"))
        for (driven in transport.driven) driven.complete()
        scope.runCurrent()
    }

    /** Why a step cannot run in this runtime yet, or null when it can. */
    private fun stop(index: Int, step: Script.Step): String? {
        if (pending != null && pending.first == index) return pending.second
        return when {
            step.action is Script.Action.Relaunch -> "the image is a later milestone"
            step.answer == "image" -> "the image is a later milestone"
            step.action is Script.Action.Event || step.action is Script.Action.Active -> "subscriptions are the next milestone"
            step.streams.isNotEmpty() -> "subscriptions are the next milestone"
            step.action is Script.Action.Attach && kind(step.action.operation) == OperationKind.SUBSCRIPTION -> "subscriptions are the next milestone"
            else -> null
        }
    }

    // The steps.

    /** Runs a step; returns what it threw. */
    private suspend fun perform(action: Script.Action): Throwable? {
        when (action) {
            is Script.Action.Commit -> {
                val operation = bind(action.operation) ?: return null
                val sent = requests(operation)
                val task = when (operation.type.kind) {
                    OperationKind.QUERY -> task { environment.fetch(operation.value as QueryOperation<*>) }
                    OperationKind.MUTATION -> mutation(operation, optimistic = null)
                    OperationKind.SUBSCRIPTION -> {
                        fail("a subscription's events are committed by an event step")
                        return null
                    }
                }
                deliver(Answering.Parts(action.responses.map { Spec.bytes(it) }), operation, sent, task)
                return task.await()
            }
            is Script.Action.Payload -> {
                val operation = bind(action.operation) ?: return null
                return task { environment.commitPayload(operation.value, Payload(Spec.bytes(action.response))) }.await()
            }
            is Script.Action.Optimistic -> {
                val operation = bind(action.operation) ?: return null
                val sent = requests(operation)
                val task = mutation(operation, Payload(Spec.bytes(action.response)))
                until { requests(operation) > sent || task.isCompleted }
                layers[action.name] = Layer(operation, task)
                return null
            }
            is Script.Action.Resolve -> {
                val layer = layers[action.layer] ?: return null.also { fail("no layer is named ${action.layer}") }
                deliver(Answering.Parts(listOf(Spec.bytes(action.response))), layer.operation, null, null)
                return layer.task.await()
            }
            is Script.Action.Revert -> {
                val layer = layers[action.layer] ?: return null.also { fail("no layer is named ${action.layer}") }
                deliver(Answering.Failure(Script.FailureKind.TRANSPORT), layer.operation, null, null)
                return layer.task.await()
            }
            is Script.Action.Attach -> {
                val operation = bind(action.operation) ?: return null
                val query = operation.value as? QueryOperation<*> ?: return null.also { fail("${operation.name} is a mutation, which has no handle") }
                val handle = environment.handle(query, action.policy)
                val live = Live(operation, handle, handle.retain())
                handles[action.name] = live
                val reply = action.reply ?: return null
                if (handle.fetch != Fetch.InFlight) return null.also { fail("the attach made no fetch for the step's reply to answer") }
                deliver(Answering.of(reply), operation, null, null)
                handle.settle()
                return null
            }
            is Script.Action.Answer -> {
                val live = handle(action.handle) ?: return null
                if (live.handle.fetch != Fetch.InFlight) return null.also { fail("${action.handle} has no fetch in flight to answer") }
                deliver(Answering.of(action.reply), live.operation, null, null)
                live.handle.settle()
                return null
            }
            is Script.Action.Refetch -> {
                val live = handle(action.handle) ?: return null
                val sent = requests(live.operation)
                val task = task { live.handle.refetch() }
                deliver(Answering.of(action.reply), live.operation, sent, task)
                return task.await()
            }
            is Script.Action.Retry -> {
                val live = handle(action.handle) ?: return null
                val sent = requests(live.operation)
                live.handle.retry()
                val reply = action.reply ?: return null
                deliver(Answering.of(reply), live.operation, sent, null)
                live.handle.settle()
                return null
            }
            is Script.Action.Release -> {
                val live = handle(action.handle) ?: return null
                live.retention?.release()
                live.retention = null
                return null
            }
            Script.Action.Collect -> {
                store.collect()
                return null
            }
            is Script.Action.Advance -> {
                store.clockOffset += action.seconds.seconds
                return null
            }
            Script.Action.Invalidate -> {
                environment.invalidate()
                return null
            }
            Script.Action.Revalidate -> {
                environment.revalidate()
                return null
            }
            is Script.Action.Check -> {
                val operation = bind(action.operation) ?: return null
                answer = store.check(store.resolve(operation.type.plan, operation.variables))
                return null
            }
            Script.Action.End -> {
                environment.end()
                return null
            }
            Script.Action.Relaunch, is Script.Action.Event, is Script.Action.Active -> {
                fail("the step is pending and does not run")
                return null
            }
        }
    }

    /** Work a step started, as a task whose value is what it threw. */
    private fun task(block: suspend () -> Unit): Deferred<Throwable?> = scope.backgroundScope.async(start = CoroutineStart.UNDISPATCHED) {
        try {
            block()
            null
        } catch (error: Throwable) {
            error
        }
    }

    /** A mutation sent in a task of its own, as an action sends it. */
    private fun mutation(operation: Bound, optimistic: Payload?): Deferred<Throwable?> {
        val mutation = operation.value as? MutationOperation<*> ?: return task { fail("${operation.name} is not a mutation") }
        return task { environment.mutate(mutation, optimistic) }
    }

    /** Runs the dispatcher's work until [condition] holds, or fails after a bound. */
    private fun until(condition: () -> Boolean) {
        repeat(100) {
            if (condition()) return
            scope.runCurrent()
        }
        if (!condition()) fail("waited for the runtime and it did not move")
    }

    private fun handle(name: String): Live? = handles[name] ?: null.also { fail("no handle is named $name") }

    /** How a step answers a request: with the parts of a response, or a failure. */
    private sealed interface Answering {
        class Parts(val parts: List<ByteArray>) : Answering
        class Failure(val kind: Script.FailureKind) : Answering

        companion object {
            fun of(reply: Script.Reply): Answering = when (reply) {
                is Script.Reply.Response -> Parts(listOf(Spec.bytes(reply.path)))
                is Script.Reply.Failure -> Failure(reply.kind)
            }
        }
    }

    /** How many requests of the operation the transport was sent. */
    private fun requests(operation: Bound): Int = transport.requests.count { operation.sent(it) }

    /**
     * Answers the newest request of the operation: one sent after the first
     * [newerThan] of its kind, or one already held. Stops waiting when the
     * work that would send it has finished without sending.
     */
    private fun deliver(answering: Answering, operation: Bound, newerThan: Int?, work: Deferred<*>?) {
        val finished = { work?.isCompleted ?: false }
        if (newerThan != null) {
            until { requests(operation) > newerThan || finished() }
        } else {
            until { transport.held.any { operation.sent(it.request) } || transport.driven.any { operation.sent(it.request) } || finished() }
        }
        val stream = transport.driven.lastOrNull { operation.sent(it.request) }
        if (stream != null) {
            when (answering) {
                is Answering.Parts -> {
                    for (part in answering.parts) stream.send(part)
                    stream.complete()
                }
                is Answering.Failure -> when (answering.kind) {
                    Script.FailureKind.TRANSPORT -> stream.fail(transportFailure)
                    Script.FailureKind.REQUEST -> {
                        stream.send(requestFailure)
                        stream.complete()
                    }
                    Script.FailureKind.MALFORMED -> {
                        stream.send(malformedResponse)
                        stream.complete()
                    }
                }
            }
            scope.runCurrent()
            return
        }
        val held = transport.held.lastOrNull { operation.sent(it.request) }
        if (held == null) {
            if (!finished()) fail("no request of ${operation.name} waits for an answer")
            return
        }
        when (answering) {
            is Answering.Parts -> {
                if (answering.parts.size != 1) fail("${operation.name} takes one response, not ${answering.parts.size} parts")
                held.respond(answering.parts.firstOrNull() ?: malformedResponse)
            }
            is Answering.Failure -> when (answering.kind) {
                Script.FailureKind.TRANSPORT -> held.refuse(transportFailure)
                Script.FailureKind.REQUEST -> held.respond(requestFailure)
                Script.FailureKind.MALFORMED -> held.respond(malformedResponse)
            }
        }
        scope.runCurrent()
    }

    // Binding an operation a step names to the class the compiler generated for it.

    private fun kind(operation: Script.Operation): OperationKind? = Spec.operation(operation.name)?.kind

    /** The operation value a step names, held or driven by the transport from now on; null, with the failure recorded, when it cannot be bound. */
    private fun bind(operation: Script.Operation): Bound? {
        val type = try {
            Class.forName("baton.spec.${operation.name}").kotlin
        } catch (_: ClassNotFoundException) {
            fail("no generated operation ${operation.name}")
            return null
        }
        val value = try {
            construct(type, operation.variables) as Operation<*>
        } catch (error: Exception) {
            fail("${operation.name} does not bind ${operation.variables}: $error")
            return null
        }
        val bound = Bound(value)
        if (bound.type.hasDeferred) transport.drive(bound.name) else transport.hold(bound.name)
        return bound
    }

    /** A generated class built from JSON by its primary constructor: a member the JSON leaves out takes its default. */
    private fun construct(type: KClass<*>, values: Map<String, Any?>): Any {
        val constructor = checkNotNull(type.primaryConstructor) { "${type.simpleName} has no primary constructor" }
        val arguments = HashMap<KParameter, Any?>()
        for (parameter in constructor.parameters) {
            val name = parameter.name ?: continue
            if (values.containsKey(name)) {
                arguments[parameter] = convert(values[name], parameter.type)
            } else if (!parameter.isOptional) {
                arguments[parameter] = null
            }
        }
        return constructor.callBy(arguments)
    }

    /** A JSON value as the Kotlin type a generated parameter takes. */
    private fun convert(value: Any?, type: KType): Any? {
        if (value == null) return null
        val classifier = type.classifier as KClass<*>
        return when {
            classifier == String::class -> value as String
            classifier == Int::class -> (value as Long).toInt()
            classifier == Long::class -> value as Long
            classifier == Double::class -> (value as Number).toDouble()
            classifier == Boolean::class -> value as Boolean
            classifier == List::class -> (value as List<*>).map { convert(it, checkNotNull(type.arguments.first().type)) }
            classifier == BigDecimal::class -> Decimals.parse(value as String)
            classifier == Instant::class -> DateTimes.parse(value as String)
            classifier == URI::class -> Urls.parse(value as String)
            classifier.isSubclassOf(GeneratedEnum::class) -> {
                val companion = checkNotNull(classifier.companionObjectInstance) { "${classifier.simpleName} has no companion" }
                companion::class.functions.first { it.name == "of" }.call(companion, value as String)
            }
            else -> {
                @Suppress("UNCHECKED_CAST")
                construct(classifier, value as Map<String, Any?>)
            }
        }
    }

    // The expectations.

    /** What the step's batches notified, slot by slot, among the fields that held a value before the step. */
    private class Observation(val cells: IdentityHashMap<Any, Script.Notification>) {
        val heard = HashSet<Script.Notification>()
        lateinit var handle: ObserverHandle
    }

    /** Observes every stored slot of every record, each on its own, so the notifications of a step are known slot by slot. */
    private fun observeEverySlot(): Observation {
        val cells = IdentityHashMap<Any, Script.Notification>()
        for ((key, record) in store.recordsByKey()) {
            record.forEachCell { slot, cell -> cells[cell] = Script.Notification(key, store.keys.text(slot)) }
        }
        val observation = Observation(cells)
        observation.handle = Snapshot.registerApplyObserver { changed, _ ->
            for (state in changed) cells[state]?.let { observation.heard.add(it) }
        }
        return observation
    }

    private fun check(step: Script.Step, thrown: Throwable?, observation: Observation?, sentBefore: Int) {
        val expectedError = step.error
        if (expectedError != null) {
            if (thrown == null) {
                fail("error: the step threw nothing where the script has $expectedError")
            } else if (kind(thrown) != expectedError) {
                fail("error: the step threw ${kind(thrown)} ($thrown) where the script has $expectedError")
            }
        } else if (thrown != null && step.action !is Script.Action.Revert) {
            fail("error: the step threw ${kind(thrown)}: $thrown")
        }

        if (observation != null) {
            Snapshot.sendApplyNotifications()
            observation.handle.dispose()
            val expected = step.notified.orEmpty().toSet()
            val extra = (observation.heard - expected).map { it.toString() }.sorted()
            val missing = (expected - observation.heard).map { it.toString() }.sorted()
            if (extra.isNotEmpty()) fail("notified: the step notified $extra, which the script does not list")
            if (missing.isNotEmpty()) fail("notified: the step did not notify $missing")
        }

        step.records?.let { records ->
            Spec.difference(store.dump(), Spec.text(records), records)?.let { fail("records: $it") }
        }

        step.recordsHeld?.let { expected ->
            val held = store.recordsByKey().keys.sorted()
            if (held != expected.sorted()) {
                fail("records_held: the store holds ${held - expected.toSet()} beyond the script's records and lacks ${expected - held.toSet()}")
            }
        }

        step.answer?.let { expected ->
            val actual = answer?.name?.lowercase() ?: "none"
            if (actual != expected) fail("answer: the check answered $actual where the script has $expected")
        }

        for (row in step.reads) read(row)

        for (expected in step.phases) {
            val live = handle(expected.handle) ?: continue
            val phase = phase(live.handle)
            if (phase != expected.phase) fail("phase: ${expected.handle} reads $phase where the script has ${expected.phase}")
            expected.isRefreshing?.let { refreshing ->
                if (live.handle.isRefreshing != refreshing) fail("phase: ${expected.handle}'s isRefreshing is ${live.handle.isRefreshing} where the script has $refreshing")
            }
            expected.isStale?.let { stale ->
                if (live.handle.isStale != stale) fail("phase: ${expected.handle}'s isStale is ${live.handle.isStale} where the script has $stale")
            }
        }

        for (expected in step.fetches) {
            val live = handle(expected.handle) ?: continue
            val fetch = fetch(live.handle.fetch)
            if (fetch != expected.fetch) fail("fetch: ${expected.handle}'s fetch is $fetch where the script has ${expected.fetch}")
        }

        step.events?.let { expected ->
            val actual = heard.map { spelled(it) }
            val matches = actual.size == expected.size && actual.zip(expected).all { (event, wanted) ->
                event.name == wanted.name && wanted.fields.all { (key, value) -> event.fields[key] == value }
            }
            if (!matches) fail("events: the log heard $actual where the script has $expected")
        }

        step.sent?.let { expected ->
            val received = transport.requests.drop(sentBefore)
            if (received.size != expected.size) {
                fail("sent: the transport received ${received.size} requests (${received.map { it.operationName }}) where the script has ${expected.size}")
            }
            for ((request, wanted) in received.zip(expected)) {
                val body = request.body.decodeToString()
                if (request.operationName != wanted.operation || body != wanted.body) {
                    fail("sent: the transport received ${request.operationName} with the body\n$body\nwhere the script has ${wanted.operation} with\n${wanted.body}")
                }
            }
        }
    }

    private fun read(row: Script.Read) {
        val data: Lens
        val name: String
        if (row.handle != null) {
            val live = handle(row.handle) ?: return
            val phase = live.handle.phase
            if (phase !is Phase.Ready) return fail("reads: ${row.handle} has no data to read ${row.path} from: it reads ${phase(live.handle)}")
            data = phase.data
            name = live.operation.name
        } else if (row.operation != null) {
            val bound = bind(Script.Operation(row.operation, row.variables)) ?: return
            data = bound.type.data(Anchor(store.root(bound.type.kind), Owner(bound.variables, store)))
            name = bound.name
        } else {
            return fail("reads: the read of ${row.path} names neither a handle nor an operation")
        }
        val value = try {
            walk(data, row.path)
        } catch (error: Throwable) {
            return fail("reads: the lens does not read ${row.path} of $name: $error")
        }
        if (!matches(value, row.value)) fail("reads: the lens reads ${row.path} of $name as $value where the script has ${row.value}")
    }

    private fun phase(handle: OperationHandle<*>): Script.State = when (val phase = handle.phase) {
        Phase.Loading -> Script.State("loading")
        is Phase.Ready -> Script.State("ready")
        is Phase.Failed -> Script.State("failed", kind(phase.error), tagged = true)
    }

    private fun fetch(fetch: Fetch): Script.State = when (fetch) {
        Fetch.Idle -> Script.State("idle")
        Fetch.InFlight -> Script.State("inFlight")
        is Fetch.Failed -> Script.State("failed", kind(fetch.failure), tagged = true)
    }

    /** A log event as a script spells it. */
    private fun spelled(event: LogEvent): Script.Event = when (event) {
        is LogEvent.FetchStarted -> Script.Event("fetchStarted", mapOf("operation" to event.operation))
        is LogEvent.FetchCompleted -> Script.Event("fetchCompleted", mapOf("operation" to event.operation))
        is LogEvent.FetchFailed -> Script.Event("fetchFailed", mapOf("operation" to event.operation, "kind" to event.kind.name.lowercase()))
        is LogEvent.Committed -> Script.Event("committed", mapOf("kind" to event.kind.name.lowercase(), "changed" to event.changed.toLong()))
        is LogEvent.FieldError -> Script.Event("fieldError", mapOf("operation" to event.operation, "path" to event.path))
        is LogEvent.Missing -> Script.Event("missing", mapOf("type" to event.type, "field" to event.field))
        is LogEvent.Unexpected -> Script.Event("unexpected", mapOf("type" to event.type, "field" to event.field))
        is LogEvent.AmbiguousIdentity -> Script.Event("ambiguousIdentity", mapOf("id" to event.id, "types" to event.types))
        is LogEvent.RequiredFieldMissing -> Script.Event("requiredFieldMissing", mapOf("type" to event.type, "path" to event.path))
        is LogEvent.PartDropped -> Script.Event("partDropped", mapOf("path" to event.path))
    }

    private companion object {
        val transportFailure = TransportError(503, "the script fails the request")

        /** Errors and no data: the server refused the request. */
        val requestFailure = """{"data":null,"errors":[{"message":"the script refuses the request"}]}""".encodeToByteArray()

        /** No data and no errors: a response no plan can read. */
        val malformedResponse = "{}".encodeToByteArray()

        /** The kind of what a step threw or a phase failed with, as a script spells it. */
        fun kind(error: Throwable): String = when (error) {
            is FieldErrors -> "fieldErrors"
            is RequiredFieldError -> "requiredField"
            is MissingDataError -> "missingData"
            is EnvironmentError -> if (error == EnvironmentError.Gone) "gone" else "environment"
            is GraphQLErrors -> "request"
            is IngestError -> "malformed"
            is Failure -> kind(error)
            else -> "transport"
        }

        fun kind(failure: Failure): String = when (failure) {
            is Failure.Transport -> "transport"
            is Failure.Request -> "request"
            is Failure.Malformed -> "malformed"
            is Failure.Environment -> "environment"
        }
    }
}
