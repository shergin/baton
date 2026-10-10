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
import androidx.tracing.trace
import baton.Environment
import baton.LogEvent
import baton.LocalBaton
import baton.Persistence
import baton.Store
import baton.macro.FixedServer
import baton.macro.Sections
import baton.sample.CharacterScreen
import baton.sample.CharactersScreen
import baton.sample.Measurement
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
 *
 * A launch whose intent carries `FixedServer.EXTRA` fetches from the fixed
 * server of `benchmarks/macro` instead, and the screens' first draws end
 * the trace sections the macrobenchmark reads; the first list drawn reports
 * the activity fully drawn.
 */
class MainActivity : ComponentActivity() {
    private val model: SampleModel by viewModels()
    private var reportedDrawn = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra(FixedServer.EXTRA, false)) {
            val server = FixedServer.start(this, FixedServer.Client.BATON)
            Measurement.avatarAddress = server::avatar
        }
        Measurement.listDrawn = {
            Sections.listDrawn()
            if (!reportedDrawn) {
                reportedDrawn = true
                reportFullyDrawn()
            }
        }
        Measurement.detailDrawn = { Sections.end(Sections.DETAIL_TAP_TO_FRAME) }
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
 * directory is the app's cache directory, passed by path. The process's
 * lifecycle is told to the environment for as long as the model lives:
 * the background parks its subscriptions, and the return revalidates.
 */
class SampleModel(application: Application) : AndroidViewModel(application) {
    val environment = trace(Sections.CLIENT_SETUP) {
        Environment(
            FixedServer.graphql("https://rickandmortyapi.com/graphql"),
            store = Store(persistence = Persistence.named("RickAndMorty", directory = application.cacheDir.path, version = Types.schemaDigest)),
        )
    }.also { environment ->
        // A page's data is in the store once the server's batch is committed; the macrobenchmark's section ends there.
        environment.log = { event -> if (event is LogEvent.Committed && event.kind == LogEvent.CommitKind.SERVER) Sections.stored() }
    }

    private val activation = Activation(environment)

    override fun onCleared() {
        activation.close()
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
        CharactersScreen(
            page = page,
            onPage = {
                if (it > page) Sections.begin(Sections.PAGE_TURN_TO_FRAME)
                page = it
            },
            onSelect = {
                Sections.begin(Sections.DETAIL_TAP_TO_FRAME)
                selected = it
            },
            modifier = modifier.fillMaxSize(),
        )
        return
    }
    BackHandler { selected = null }
    Column(modifier.fillMaxSize()) {
        TextButton(onClick = { selected = null }) { Text("Characters") }
        HorizontalDivider()
        CharacterScreen(id = id)
    }
}
