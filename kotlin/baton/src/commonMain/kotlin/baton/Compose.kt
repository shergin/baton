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
 * outside every provider, where a query reads failed with
 * `EnvironmentError.NotInjected` and a subscription has no handle.
 */
val LocalBaton = staticCompositionLocalOf<Environment?> { null }

/**
 * What a composable remembers of an operation, and the hold that keeps its
 * records alive while the composable stays in the composition; released
 * when it leaves, when what it is keyed on changes, or when a composition
 * that made it is abandoned. No hold outside every environment.
 */
private class Remembered<Value>(val value: Value, private val hold: Hold?) : RememberObserver {
    override fun onRemembered() {}

    override fun onForgotten() {
        hold?.release()
    }

    override fun onAbandoned() {
        hold?.release()
    }
}

/**
 * The query's state in the composition: the handle the value resolves to in the
 * environment [LocalBaton] provides, retained while the composable stays
 * and released when it leaves, and the `phase`, `fetch`, `isRefreshing`,
 * `isStale`, `retry()` and `refetch()` that read it. An equal value under
 * the same policy keeps its handle across recompositions; a changed value,
 * another policy, or another environment resolves anew, the policy applied
 * on that attach, and the earlier hold is released. Outside every provider
 * no handle is made and the phase reads failed with
 * `EnvironmentError.NotInjected`. The value given is not written to.
 */
@Composable
fun <Data : Lens, Op : QueryOperation<Data>> rememberQuery(operation: Op, fetchPolicy: FetchPolicy = FetchPolicy.Default): QueryState<Op, Data> {
    val environment = LocalBaton.current
    // Remembered on every entry, so a composable that gains or loses the
    // provider keeps its slot, and keyed on the policy, so a policy passed
    // anew is applied; the attach stays inside the calculation, once per key.
    val remembered = remember(operation, environment, fetchPolicy) {
        if (environment == null) return@remember Remembered(QueryState(operation, null), null)
        val handle = environment.handle(operation, fetchPolicy)
        Remembered(QueryState(operation, handle), handle.retain())
    }
    return remembered.value
}

/**
 * The action that commits a mutation through the environment [LocalBaton]
 * provides, by the mutation's generated companion; generated code gives it
 * an `invoke` with one argument per variable. Outside every provider its
 * commit throws `EnvironmentError.NotInjected`.
 */
@Composable
fun <Op : MutationOperation<Data>, Data : Lens> rememberMutation(type: MutationType<Op, Data>): MutationAction<Op, Data> {
    val environment = LocalBaton.current
    return remember(type, environment) { MutationAction(environment) }
}

/**
 * The handle a subscription value resolves to in the environment
 * [LocalBaton] provides: its stream is open while the composable stays and
 * closed when it leaves, and an equal value recomposed keeps it. Null
 * outside every provider, where no handle is made.
 */
@Composable
fun <Data : Lens, Op : SubscriptionOperation<Data>> rememberSubscription(operation: Op): SubscriptionHandle<Data>? {
    val environment = LocalBaton.current
    val remembered = remember(operation, environment) {
        if (environment == null) return@remember Remembered<SubscriptionHandle<Data>?>(null, null)
        val handle = environment.subscriptionHandle(operation)
        Remembered(handle, handle.retain())
    }
    return remembered.value
}
