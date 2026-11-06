package baton

import java.nio.ByteBuffer

/** A buffer compare, which HotSpot runs as one vectorized mismatch; ART runs it as a loop. */
internal actual fun ByteArray.regionsEqual(first: Int, second: Int, length: Int): Boolean =
    ByteBuffer.wrap(this, first, length) == ByteBuffer.wrap(this, second, length)
