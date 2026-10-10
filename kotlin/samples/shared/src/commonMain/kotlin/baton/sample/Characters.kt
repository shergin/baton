package baton.sample

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import baton.Environment
import baton.inspector.StoreInspector

/** Material 3's light or dark colors, as the system's appearance is. */
@Composable
fun SampleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(), content = content)
}

/**
 * The list beside the detail pane, for a wide window, and the store
 * inspector over [inspected] when it is given; a character to start from,
 * for the screenshot. Selecting a character starts the pane's stack over;
 * what a screen opens, an episode, a location, a cast member, is pushed on
 * it, and Back pops.
 */
@Composable
fun Characters(initialSelection: String? = null, inspected: Environment? = null) {
    var page by remember { mutableStateOf(1) }
    var stack by remember(initialSelection) { mutableStateOf(initialSelection?.let { listOf<Destination>(Destination.Character(it)) }.orEmpty()) }
    Row {
        CharactersScreen(page = page, onPage = { page = it }, onSelect = { stack = listOf(Destination.Character(it)) }, modifier = Modifier.width(360.dp).fillMaxHeight())
        VerticalDivider()
        Column(modifier = Modifier.weight(1f).fillMaxHeight()) {
            val top = stack.lastOrNull()
            if (top == null) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Select a character.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                if (stack.size > 1) {
                    TextButton(onClick = { stack = stack.dropLast(1) }) { Text("Back") }
                    HorizontalDivider()
                }
                DestinationScreen(top, onOpen = { stack = stack + it })
            }
        }
        if (inspected != null) {
            VerticalDivider()
            StoreInspector(inspected, modifier = Modifier.width(320.dp).fillMaxHeight())
        }
    }
}
