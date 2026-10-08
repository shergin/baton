package baton.testing

import baton.Request
import baton.Transport
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** Never answers; for exercising what shows before a response, without a network. */
class SilentTransport : Transport {
    override fun send(request: Request): Flow<ByteArray> = flow { awaitCancellation() }
}
