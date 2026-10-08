package baton.sample

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import baton.Environment
import baton.LocalBaton
import baton.Persistence
import baton.Store

/**
 * The sample: the public Rick and Morty API through Baton. The characters
 * and the detail share one store, so a character seen in the list is the
 * record the detail reads, and its header draws from the store before the
 * network answers.
 */
fun main() = application {
    // Made in the composition, on the event thread the store belongs to. The
    // store keeps its image in the user's cache directory under the schema's
    // digest, so the next launch shows what this one fetched before the
    // network answers, and starts again when the schema changes.
    val environment = remember {
        Environment(
            "https://rickandmortyapi.com/graphql",
            store = Store(persistence = Persistence.named("RickAndMorty", version = Types.schemaDigest)),
        )
    }
    Window(onCloseRequest = ::exitApplication, title = "Rick and Morty", state = rememberWindowState(size = DpSize(960.dp, 720.dp))) {
        MaterialTheme {
            Surface(modifier = Modifier.fillMaxSize()) {
                CompositionLocalProvider(LocalBaton provides environment) {
                    Characters()
                }
            }
        }
    }
}

/** The list beside the detail of the character selected in it; a selection to start from, for the screenshot. */
@Composable
internal fun Characters(initialSelection: String? = null) {
    var page by remember { mutableStateOf(1) }
    var selected by remember(initialSelection) { mutableStateOf(initialSelection) }
    Row {
        CharactersScreen(page = page, onPage = { page = it }, onSelect = { selected = it }, modifier = Modifier.width(360.dp).fillMaxHeight())
        VerticalDivider()
        val id = selected
        if (id == null) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Select a character.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            CharacterScreen(id = id)
        }
    }
}
