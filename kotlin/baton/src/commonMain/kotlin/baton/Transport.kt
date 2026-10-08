package baton

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.firstOrNull

/**
 * One operation execution over the wire: the operation's name, its kind, its
 * document (the text the compiler printed or the id it was registered under,
 * never both), its variables, the `onError` value when `baton.json` names
 * one, and whether the response may arrive in parts. See `spec/runtime.md`,
 * section 10.
 */
class Request(
    val operationName: String,
    val kind: OperationKind,
    val document: Document,
    val variables: Variables,
    val errorBehavior: ErrorBehavior? = null,
    val incremental: Boolean = false,
) {
    /** The JSON a server receives for the request, by the standard encoding. */
    val body: ByteArray get() = Encoding.standard.body(this)

    override fun toString(): String = "Request($operationName)"
}

/**
 * The one function from a request to the JSON a server receives. The standard
 * one writes `operationName`, then `query` for a text or `documentId` for an
 * id, then `variables`, then `onError` when set, as one object, after the
 * GraphQL-over-HTTP working group's proposal. A server with another
 * convention replaces the function and keeps the built-in transports.
 */
class Encoding(val body: (Request) -> ByteArray) {
    companion object {
        val standard: Encoding = Encoding { request ->
            val json = StringBuilder()
            json.append("{\"operationName\":").append(Variable.quote(request.operationName))
            when (val document = request.document) {
                is Document.Text -> json.append(",\"query\":").append(Variable.quote(document.text))
                is Document.Id -> json.append(",\"documentId\":").append(Variable.quote(document.id))
            }
            json.append(",\"variables\":").append(request.variables.json)
            request.errorBehavior?.let { json.append(",\"onError\":").append(Variable.quote(it.wire)) }
            json.append('}')
            json.toString().encodeToByteArray()
        }
    }
}

/**
 * One verb: a request yields a flow of payloads, each a GraphQL response
 * body. A query's or a mutation's flow carries one payload; a deferred
 * response's its parts, the first with `data`; a subscription's its events.
 * A wrapper wraps one method, whatever the operation's kind. A failure with
 * no response is a `TransportError` of status 0 that says what went wrong.
 */
interface Transport {
    fun send(request: Request): Flow<ByteArray>
}

/** The one payload of a request that answers once: the flow's first, or the failure a flow that delivers none is. */
suspend fun Transport.payload(request: Request): ByteArray =
    send(request).firstOrNull() ?: throw TransportError(0, "the transport delivered no payload for ${request.operationName}")
