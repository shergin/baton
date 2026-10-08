package baton

import androidx.compose.runtime.Composable
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf

// The composables: the environment a tree reads, and the remembered handles
// and actions the markers' composables hold. A handle's phase, its fetch, its
// staleness and every lens read are snapshot state already, so a composable
// that reads them recomposes when they move, and only then.

/**
 * The Baton environment for a composition tree, provided on an ancestor:
 * `CompositionLocalProvider(LocalBaton provides environment) { ... }`. Null
 * outside every provider, where an operation reads failed with
 * `EnvironmentError.NotInjected`.
 */
val LocalBaton = staticCompositionLocalOf<Environment?> { null }

/**
 * A handle and the retention that keeps its records alive while the
 * composable that remembered it stays in the composition; released when it
 * leaves, or when a composition that made it is abandoned.
 */
private class Remembered<Handle : Any>(val handle: Handle, private val retention: Retention) : RememberObserver {
    override fun onRemembered() {}

    override fun onForgotten() {
        retention.release()
    }

    override fun onAbandoned() {
        retention.release()
    }
}

/**
 * Resolves a query value to its handle in the environment [LocalBaton]
 * provides and returns the value, carrying its resolution: its `phase`,
 * `fetch`, `isRefreshing` and `isStale` read the handle. The handle is
 * retained while the composable stays, and released when it leaves. An
 * equal value recomposed keeps its handle; a changed value, or another
 * environment, resolves anew, the policy applied on that attach. Outside
 * every provider no handle is made, and the phase reads failed with
 * `EnvironmentError.NotInjected`.
 */
@Composable
fun <Data : Lens, Op : QueryOperation<Data>> rememberQuery(operation: Op, fetchPolicy: FetchPolicy = FetchPolicy.Default): Op {
    val environment = LocalBaton.current
    if (environment == null) {
        operation.resolution = Resolution.NotInjected
        return operation
    }
    val remembered = remember(operation, environment) {
        val handle = environment.handle(operation, fetchPolicy)
        Remembered(handle, handle.retain())
    }
    operation.resolution = Resolution.Resolved(remembered.handle)
    return operation
}

/**
 * The action that commits a mutation through the environment [LocalBaton]
 * provides, by the mutation's generated companion; generated code gives it
 * an `invoke` with one argument per variable. Outside every provider its
 * commit throws `EnvironmentError.NotInjected`.
 */
@Composable
fun <Op : MutationOperation<Data>, Data : Lens> rememberMutation(type: OperationType<Data>): MutationAction<Op, Data> {
    val environment = LocalBaton.current
    return remember(type, environment) { MutationAction(environment) }
}

/**
 * Resolves a subscription value to its handle in the environment
 * [LocalBaton] provides and returns the value, carrying its resolution: its
 * `subscription` is the handle. The stream is open while the composable
 * stays, and closed when it leaves; an equal value recomposed keeps it.
 * Outside every provider no handle is made and `subscription` is null.
 */
@Composable
fun <Data : Lens, Op : SubscriptionOperation<Data>> rememberSubscription(operation: Op): Op {
    val environment = LocalBaton.current
    if (environment == null) {
        operation.resolution = Resolution.NotInjected
        return operation
    }
    val remembered = remember(operation, environment) {
        val handle = environment.subscriptionHandle(operation)
        Remembered(handle, handle.retain())
    }
    operation.resolution = Resolution.Resolved(remembered.handle)
    return operation
}
