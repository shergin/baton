package baton

// `Thread.threadId()` is Java 19's; the runtime targets older JVMs too.
@Suppress("DEPRECATION")
internal actual fun currentThreadId(): Long = Thread.currentThread().id
