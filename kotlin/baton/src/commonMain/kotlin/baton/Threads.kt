package baton

/**
 * The calling thread's identity, which a store compares with its own at
 * every entry point: a store belongs to the thread that made it.
 */
internal expect fun currentThreadId(): Long

/**
 * A mutual exclusion lock, the platform's, since common Kotlin has none:
 * what the store's thread and another read and write in turn, the store's
 * keys and the image's state, lives under one.
 */
internal expect class Lock() {
    fun lock()
    fun unlock()
}

/** Runs [body] with the lock held, and lets it go however [body] leaves. */
internal inline fun <T> Lock.withLock(body: () -> T): T {
    lock()
    try {
        return body()
    } finally {
        unlock()
    }
}
