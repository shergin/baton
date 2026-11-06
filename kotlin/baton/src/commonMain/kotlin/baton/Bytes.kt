package baton

/**
 * Whether the [length] bytes at [first] equal those at [second]; the caller
 * has checked both ranges are inside the array. The platform compares as
 * it can: the JVM's buffer compare is vectorized, where a loop is not.
 */
internal expect fun ByteArray.regionsEqual(first: Int, second: Int, length: Int): Boolean
