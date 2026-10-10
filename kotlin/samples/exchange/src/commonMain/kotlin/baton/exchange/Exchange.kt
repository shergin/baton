package baton.exchange

import baton.OperationKind
import baton.Request
import baton.Transport
import baton.TransportError
import kotlin.coroutines.cancellation.CancellationException
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * The exchange an app owns around Baton's one verb: the few dozen lines a
 * production endpoint needs and the library does not ship, since they
 * compose what it has. Credentials are the base transport's own, read per
 * attempt; this adds one replay of an authorization challenge, a bounded
 * retry with backoff over the outcomes a retry can mend, a deadline that
 * spans every attempt, and the rule that a mutation is never sent twice,
 * since the server may have received it. Copy it, and change the numbers
 * to the endpoint's.
 */
class Exchange(
    /** The transport this wraps, which holds the endpoint and its credentials. */
    val base: Transport,
    /** How many times a query or a subscription is sent, at most; the replay of a challenge is not counted. */
    val attempts: Int = 3,
    /** The whole exchange, across every attempt and the waits between them. */
    val deadline: Duration = 30.seconds,
    /** The first wait before a retry, doubled at each further one. */
    val step: Duration = 500.milliseconds,
    /**
     * Called once per request on a 401, before the one replay; the base
     * transport's `credentials` function then reads the renewed token.
     */
    val challenged: suspend () -> Unit = {},
) : Transport {
    override fun send(request: Request): Flow<ByteArray> = flow {
        val started = TimeSource.Monotonic.markNow()
        var replayed = false
        var retries = 0
        while (true) {
            var delivered = false
            try {
                base.send(request).collect { payload ->
                    delivered = true
                    emit(payload)
                }
                return@flow
            } catch (error: Throwable) {
                // The collector going away is not the attempt's failure.
                if (error is CancellationException) throw error
                // A stream that delivered is not sent again: the caller has
                // part of the answer, and a stream resumes nothing.
                if (delivered) throw error
                // A 401 was refused before execution, so even a mutation is
                // sent once more, with the renewed token.
                if (error is TransportError && error.statusCode == 401 && !replayed) {
                    replayed = true
                    challenged()
                    continue
                }
                // A mutation is never sent twice: the server may have
                // received it.
                if (request.kind == OperationKind.MUTATION || !mends(error) || retries + 1 >= attempts) throw error
                // The wait doubles and is jittered; the deadline covers the
                // wait as well as the attempt.
                val pause = step * (1 shl minOf(retries, 10))
                val wait = pause / 2 + pause / 2 * Random.nextDouble()
                if (started.elapsedNow() + wait >= deadline) throw error
                delay(wait)
                retries += 1
            }
        }
    }

    companion object {
        /**
         * Whether a retry may mend a failure: a 5xx status, or a connection
         * that was lost or timed out, which the transport reports as a
         * status 0 with the connection's failure as its cause. A 4xx other
         * than 401, a request error, a malformed response and a request the
         * transport could not make would repeat.
         */
        fun mends(error: Throwable): Boolean {
            if (error !is TransportError) return false
            if (error.statusCode in 500..599) return true
            return error.statusCode == 0 && error.cause != null
        }
    }
}
