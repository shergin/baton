package baton.testing

import baton.OperationKind
import baton.Request
import baton.Transport
import baton.TransportError
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow

/**
 * A transport an app's tests script: it answers operations by name or
 * through a responder, holds a mutation, or any operation it is told to
 * hold, until the test replies or refuses, lets the test drive a stream of
 * parts or events by hand, and keeps every request it was sent. Not a mock:
 * it is a transport like any other, and nothing behind it can tell.
 *
 * An operation with no answer scripted fails with a `TransportError` of
 * status 0 that says so; a mutation with none is held instead, since a test
 * usually wants the window between an optimistic apply and the server's
 * answer. A request is recorded when its flow is collected, which is when
 * it is sent.
 */
@OptIn(ExperimentalAtomicApi::class)
class ScriptedTransport(
    answers: Map<String, ByteArray> = emptyMap(),
    private val holdsMutations: Boolean = true,
    private val responder: ((Request) -> ByteArray?)? = null,
) : Transport {
    /** A request held until the test answers it. */
    class Held internal constructor(val request: Request, internal val token: Long, private val channel: SendChannel<ByteArray>) {
        /** Answers the request with one payload and ends its flow. */
        fun respond(data: ByteArray) {
            channel.trySend(data)
            channel.close()
        }

        /** Fails the request. */
        fun refuse(error: Throwable) {
            channel.close(error)
        }
    }

    /** A flow the test drives: a subscription's events, or the parts of a deferred response. */
    class Driven internal constructor(val request: Request, internal val token: Long, private val channel: SendChannel<ByteArray>) {
        /** Delivers one payload. */
        fun send(data: ByteArray) {
            channel.trySend(data)
        }

        /** Ends the flow, as a server completing it does. */
        fun complete() {
            channel.close()
        }

        /** Ends the flow with a failure. */
        fun fail(error: Throwable) {
            channel.close(error)
        }
    }

    private class State(
        val answers: Map<String, ByteArray>,
        val holding: Set<String>,
        val driving: Set<String>,
        val sent: List<Request>,
        val held: List<Held>,
        val driven: List<Driven>,
        /** Numbers each send, so a flow's end forgets its own entry and not an equal request's. */
        val tokens: Long,
    ) {
        fun copy(
            answers: Map<String, ByteArray> = this.answers,
            holding: Set<String> = this.holding,
            driving: Set<String> = this.driving,
            sent: List<Request> = this.sent,
            held: List<Held> = this.held,
            driven: List<Driven> = this.driven,
            tokens: Long = this.tokens,
        ) = State(answers, holding, driving, sent, held, driven, tokens)
    }

    private val state = AtomicReference(State(answers, emptySet(), emptySet(), emptyList(), emptyList(), emptyList(), 0))

    private inline fun <T> update(transform: (State) -> Pair<State, T>): T {
        while (true) {
            val current = state.load()
            val (next, result) = transform(current)
            if (state.compareAndSet(current, next)) return result
        }
    }

    /** Scripts the answer to every request of the operation. */
    fun answer(operationName: String, data: ByteArray) {
        update { it.copy(answers = it.answers + (operationName to data)) to Unit }
    }

    /** Holds every request of the operation until the test answers it. */
    fun hold(operationName: String) {
        update { it.copy(holding = it.holding + operationName) to Unit }
    }

    /** Lets the test drive every request of the operation as a flow. */
    fun drive(operationName: String) {
        update { it.copy(driving = it.driving + operationName) to Unit }
    }

    /** The requests held, oldest first; answering one takes it off the list. */
    val held: List<Held> get() = state.load().held

    /** The flows the test drives, oldest first. */
    val driven: List<Driven> get() = state.load().driven

    /** The requests the transport was sent, in the order they were sent. */
    val requests: List<Request> get() = state.load().sent

    val requestCount: Int get() = state.load().sent.size

    /** The requests of one kind. */
    fun requests(kind: OperationKind): List<Request> = state.load().sent.filter { it.kind == kind }

    /** What a send does: drive the flow, answer it now, hold it, or fail it. */
    private sealed interface Decision {
        class Drive(val token: Long) : Decision
        class Answer(val data: ByteArray) : Decision
        class Hold(val token: Long) : Decision
        data object Refuse : Decision
    }

    override fun send(request: Request): Flow<ByteArray> = channelFlow {
        val channel = this
        val decision = update { current ->
            val token = current.tokens + 1
            val sent = current.copy(sent = current.sent + request, tokens = token)
            val name = request.operationName
            val answered = current.answers[name]
            val unanswered = answered == null && responder == null
            when {
                name in current.driving || (request.kind == OperationKind.SUBSCRIPTION && unanswered) ->
                    sent.copy(driven = sent.driven + Driven(request, token, channel)) to Decision.Drive(token)
                else -> {
                    val data = responder?.invoke(request) ?: answered
                    when {
                        data != null -> sent to Decision.Answer(data)
                        name in current.holding || (request.kind == OperationKind.MUTATION && holdsMutations) ->
                            sent.copy(held = sent.held + Held(request, token, channel)) to Decision.Hold(token)
                        else -> sent to Decision.Refuse
                    }
                }
            }
        }
        when (decision) {
            is Decision.Answer -> send(decision.data)
            is Decision.Drive -> awaitClose { update { it.copy(driven = it.driven.filter { driven -> driven.token != decision.token }) to Unit } }
            is Decision.Hold -> awaitClose { update { it.copy(held = it.held.filter { held -> held.token != decision.token }) to Unit } }
            Decision.Refuse -> throw TransportError(0, "no answer scripted for ${request.operationName}")
        }
    }
}
