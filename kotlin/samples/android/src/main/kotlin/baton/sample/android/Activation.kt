package baton.sample.android

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import baton.Environment

/**
 * The app's lifecycle, told to an environment on Android. An app in the
 * background parks its retained subscriptions; an app coming back to the
 * foreground resumes them and refetches what went stale or failed while it
 * was away. The lifecycle is the process's, not an activity's: the
 * environment is the app's, and an activity recreated for a rotation does
 * not make the app inactive. The observer is called on the main thread,
 * where the store lives, and the environment's owner closes it when the
 * environment ends. Nothing in the runtime depends on the lifecycle
 * library; the wiring is the app's.
 */
class Activation(
    private val environment: Environment,
    private val lifecycle: Lifecycle = ProcessLifecycleOwner.get().lifecycle,
) : DefaultLifecycleObserver {
    init {
        lifecycle.addObserver(this)
    }

    override fun onStart(owner: LifecycleOwner) {
        environment.isActive = true
        environment.revalidate()
    }

    override fun onStop(owner: LifecycleOwner) {
        environment.isActive = false
    }

    /** Stops telling the environment, before it ends. */
    fun close() {
        lifecycle.removeObserver(this)
    }
}
