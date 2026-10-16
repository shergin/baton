# Views and view models: a handle without a composition

Baton's Kotlin reads are synchronous on the store's thread, and its
handles are snapshot state. A screen with no composition uses them
without Compose UI: a `ViewModel` behind Android Views, a desktop window,
a service. You ask the environment for the handle, hold the retention that
keeps the handle's data alive, and read what the screen shows through
`snapshotFlow`. The flow emits again when a field it read changed. Nothing
here is a second API. It is the same handle `rememberQuery` resolves. This
is the Kotlin twin of [derived state outside views](derived-state.md),
where Swift reads through `Observations`.

The code below is compiled in this repository, as `ViewsTests` under
`kotlin/baton/src/jvmTest`. That test proves what this page says of it.

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

Collect the flow on the main dispatcher, where the store is read, and
render each screen as it comes:

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
a composition does. The flow emits when one of them changes, and stays
quiet when nothing it read did. A response that changes a field no row
shows emits nothing.

## What sends the change

Compose UI's frame clock sends the snapshot system's apply notifications.
That is what `snapshotFlow` listens for. Without a composition, nothing
would, so the environment sends them itself. It observes the writes the
runtime makes: a commit's cells, a handle's fetch, a root's date. It
posts one send behind each burst of them, on its main dispatcher. With
Compose UI present, the frame clock sends the same notifications.
Whichever comes second finds nothing left to send.

## Release

The hold is the retention. The handle's data stays in the store while the
model holds it, and is collected after the model releases it, as leaving
the composable releases `rememberQuery`'s. A `ViewModel` releases the
hold in `onCleared`. A window releases it when the window closes.

## The app's lifecycle

`environment.isActive` parks the retained subscriptions while it is false,
and resumes them when it is true again. `environment.revalidate()`
refetches the retained operations that went stale or failed. The app says
when, from its own lifecycle, and holds the observer for as long as the
environment lives. On Android the lifecycle is the process's,
`ProcessLifecycleOwner` from `androidx.lifecycle:lifecycle-process`, not
an activity's. The environment is the app's. An activity recreated for a
rotation does not make the app inactive. The code below is `Activation.kt`
in
[`kotlin/samples/android`](../../kotlin/samples/android/src/main/kotlin/baton/sample/android/Activation.kt),
compiled with the sample. Its view model makes one beside the environment
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
writes land where the environment's synchronous calls do. `ON_STOP`
arrives once the last activity has stopped, after the short delay the
lifecycle library keeps so a configuration change sends nothing.
`ON_START` arrives with the first activity. Adding the observer to a
started lifecycle delivers `ON_START` at once. A revalidation with nothing
retained does nothing. The runtime depends on no lifecycle library. The
wiring is the app's, as `examples/Controllers` is on iOS and macOS
([`uikit.md`](uikit.md#the-apps-lifecycle)).

On the desktop, a window stays on screen while another app is frontmost,
so the desktop samples park nothing. An app that wants a revalidation
when a window regains focus calls `revalidate()` from the window's focus
listener.
