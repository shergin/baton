# Views and view models: a handle without a composition

Baton's Kotlin reads are synchronous on the store's thread and its handles
are snapshot state, so a screen with no composition, a `ViewModel` behind
Android Views, a desktop window, a service, uses them without Compose UI:
it asks the environment for the handle, holds the retention that keeps
the handle's data alive, and reads what it shows through `snapshotFlow`,
which emits again when a field it read changed. Nothing here is a second
API; it is the same handle `rememberQuery` resolves. This is the Kotlin
twin of [derived state outside views](derived-state.md), where Swift
reads through `Observations`.

The code below is compiled in this repository, as `ViewsTests` under
`kotlin/baton/src/jvmTest`, which proves what this page says of it.

## The model

```kotlin
import androidx.compose.runtime.snapshotFlow
import baton.Environment
import baton.FetchPolicy
import baton.Hold
import baton.OperationHandle
import baton.Phase
import kotlinx.coroutines.flow.Flow

/** What the screen shows: the rows, or why there are none yet. */
sealed interface Screen {
    data object Loading : Screen
    data class Rows(val names: List<String>) : Screen
    data class Failed(val error: Throwable) : Screen
}

class CharactersModel(environment: Environment) {
    // The handle the value resolves to, retained while the model lives.
    private val handle: OperationHandle<CharactersQuery.Data> =
        environment.handle(CharactersQuery(page = 1), FetchPolicy.Default)
    private val hold: Hold = handle.retain()

    // What the screen shows, read inside the block: the fields the block
    // reads are what the flow listens to, so a response that renames one
    // row emits new rows. A ready phase alone is equal across reads, and a
    // flow of phases would not emit for a field.
    val screen: Flow<Screen> = snapshotFlow {
        when (val phase = handle.phase) {
            is Phase.Ready -> Screen.Rows(phase.data.characters.results.map { it.name })
            Phase.Loading -> Screen.Loading
            is Phase.Failed -> Screen.Failed(phase.error)
        }
    }

    fun refetch() = handle.retry()

    fun close() = hold.release()
}
```

The flow is collected on the main dispatcher, where the store is read, and
each screen is rendered as it comes:

```kotlin
scope.launch(Dispatchers.Main.immediate) {
    model.screen.collect { screen ->
        when (screen) {
            is Screen.Rows -> adapter.submitList(screen.names)
            Screen.Loading -> spinner.isVisible = true
            is Screen.Failed -> showError(screen.error)
        }
    }
}
```

A lens read inside the block registers the fields it reads, as a read in
a composition does, so the flow emits when one of them changes and stays
quiet when nothing it read did: a response that changes a field no row
shows emits nothing.

## What sends the change

Compose UI's frame clock sends the snapshot system's apply notifications,
which is what `snapshotFlow` listens for. Without a composition nothing
would, so the environment sends them itself: it observes the writes the
runtime makes, a commit's cells, a handle's fetch, a root's date, and
posts one send behind each burst of them on its main dispatcher. With
Compose UI present the frame clock sends the same notifications, and
whichever comes second finds nothing left to send.

## Release

The hold is the retention: the handle's data stays in the store while the
model holds it, and is collected after the model releases it, as the
composable's leaving releases `rememberQuery`'s. A `ViewModel` releases it
in `onCleared`; a window when it closes.

## The app's lifecycle

`environment.isActive` parks the retained subscriptions while it is false
and resumes them when it is true again; `environment.revalidate()` refetches
the retained operations that went stale or failed. The app says when, from
its own lifecycle, and holds the observer for as long as the environment
lives. On Android the lifecycle is the process's, `ProcessLifecycleOwner`
from `androidx.lifecycle:lifecycle-process`, not an activity's: the
environment is the app's, and an activity recreated for a rotation does
not make the app inactive. The code below is `Activation.kt` in
[`kotlin/samples/android`](../../kotlin/samples/android/src/main/kotlin/baton/sample/android/Activation.kt),
compiled with the sample; its view model makes one beside the environment
and closes it in `onCleared`, before the environment ends.

```kotlin
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
```

The observer is called on the main thread, where the store lives, so the
writes are made where the environment's synchronous calls are. `ON_STOP`
arrives once the last activity has stopped, after the short delay the
lifecycle library keeps so a configuration change sends nothing, and
`ON_START` with the first activity; adding the observer to a started
lifecycle delivers `ON_START` at once, and a revalidation with nothing
retained does nothing. The runtime depends on no lifecycle library; the
wiring is the app's, as `examples/Controllers` is on iOS and macOS
([`uikit.md`](uikit.md#the-apps-lifecycle)).

On the desktop a window stays on screen while another app is frontmost, so
the desktop samples park nothing; an app that wants a revalidation when a
window regains focus calls `revalidate()` from the window's focus listener.
