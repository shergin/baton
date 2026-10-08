package baton.testing

import baton.Request
import baton.Transport
import baton.TransportError
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * Serves recorded responses by operation name, or through a responder that
 * sees the whole request; for tests, previews and benchmarks. An operation
 * with nothing recorded fails with a `TransportError` of status 0 that says
 * so. A request is recorded when its flow is collected, which is when it is
 * sent.
 */
@OptIn(ExperimentalAtomicApi::class)
class RecordedTransport private constructor(
    responses: Map<String, ByteArray>,
    private val responder: ((Request) -> ByteArray?)?,
) : Transport {
    /** Answers from [responses] by operation name. */
    constructor(responses: Map<String, ByteArray> = emptyMap()) : this(responses, null)

    /** Answers through [responder], which sees the whole request; a request it answers null for falls back to the recorded responses. */
    constructor(responder: (Request) -> ByteArray?) : this(emptyMap(), responder)

    private val responses = AtomicReference(responses)
    private val sent = AtomicReference(emptyList<Request>())

    /** Records the response to every request of the operation. */
    fun record(operationName: String, data: ByteArray) {
        while (true) {
            val current = responses.load()
            if (responses.compareAndSet(current, current + (operationName to data))) return
        }
    }

    /** The requests the transport was sent, in order. */
    val requests: List<Request> get() = sent.load()

    val requestCount: Int get() = sent.load().size

    override fun send(request: Request): Flow<ByteArray> = flow {
        while (true) {
            val current = sent.load()
            if (sent.compareAndSet(current, current + request)) break
        }
        val data = responder?.invoke(request)
            ?: responses.load()[request.operationName]
            ?: throw TransportError(0, "no recorded response for ${request.operationName}")
        emit(data)
    }
}
