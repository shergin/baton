# Views and view models: a handle without a composition

Baton's Kotlin reads are synchronous on the store's thread and its handles
are snapshot state, so a screen with no composition, a `ViewModel` behind
Android Views, a desktop window, a service, uses them without Compose UI:
it asks the environment for the handle, holds the retention that keeps
the handle's data alive, and reads what it shows through `snapshotFlow`,
which emits again when a field it read changed. Nothing here is a second
API; it is the same handle `rememberQuery` resolves.

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
