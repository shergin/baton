package baton

/**
 * The calling thread's identity, which a store compares with its own at
 * every entry point: a store belongs to the thread that made it.
 */
internal expect fun currentThreadId(): Long
