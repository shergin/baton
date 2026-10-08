package baton.sample.android

import android.app.Application
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.AndroidViewModel
import baton.Environment
import baton.LocalBaton
import baton.Persistence
import baton.Store
import baton.sample.CharacterScreen
import baton.sample.CharactersScreen
import baton.sample.SampleTheme
import baton.sample.Types
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * The sample on a phone: the public Rick and Morty API through Baton, the
 * characters a page at a time, and a character's detail when one is
 * selected; back returns to the list. The environment lives in a view
 * model, so it outlives a rotation, and its store keeps its image in the
 * app's cache directory under the schema's digest, so the next launch shows
 * what this one fetched before the network answers.
 */
class MainActivity : ComponentActivity() {
    private val model: SampleModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SampleTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    CompositionLocalProvider(LocalBaton provides model.environment) {
                        Characters(modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing))
                    }
                }
            }
        }
    }
}

/**
 * The environment, made on the main thread with the view model, which the
 * activity makes there. The runtime holds no `Context`: the image's
 * directory is the app's cache directory, passed by path.
 */
class SampleModel(application: Application) : AndroidViewModel(application) {
    val environment = Environment(
        "https://rickandmortyapi.com/graphql",
        store = Store(persistence = Persistence.named("RickAndMorty", directory = application.cacheDir.path, version = Types.schemaDigest)),
    )

    override fun onCleared() {
        // The view model's own scope is cancelled by now. The end writes what
        // the store handed the image and gives the file back, so the next
        // activity's environment in this process can take it.
        CoroutineScope(Dispatchers.Main).launch { environment.end() }
    }
}

/** The list, or the detail of the character selected in it, one at a time. */
@Composable
private fun Characters(modifier: Modifier = Modifier) {
    var page by rememberSaveable { mutableStateOf(1) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val id = selected
    if (id == null) {
        CharactersScreen(page = page, onPage = { page = it }, onSelect = { selected = it }, modifier = modifier.fillMaxSize())
        return
    }
    BackHandler { selected = null }
    Column(modifier.fillMaxSize()) {
        TextButton(onClick = { selected = null }) { Text("Characters") }
        HorizontalDivider()
        CharacterScreen(id = id)
    }
}
