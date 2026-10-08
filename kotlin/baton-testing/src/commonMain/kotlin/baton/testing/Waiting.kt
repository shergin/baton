package baton.testing

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.yield

/**
 * Waits for [until] to hold, yielding to the coroutines it depends on between
 * checks, until it holds or [timeout] passes on the monotonic clock: true
 * when it held. For an app's tests over a scripted transport, where a handle
 * settles a few hops after the answer; the test records the failure.
 */
suspend fun wait(until: () -> Boolean, timeout: Duration = 10.seconds): Boolean {
    val deadline = TimeSource.Monotonic.markNow() + timeout
    while (!until()) {
        if (deadline.hasPassedNow()) return false
        yield()
    }
    return true
}
