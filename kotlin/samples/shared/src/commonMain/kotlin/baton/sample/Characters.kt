package baton.sample

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
 * The list beside the detail of the character selected in it, for a wide
 * window, and the store inspector over [inspected] when it is given; a
 * selection to start from, for the screenshot.
 */
@Composable
fun Characters(initialSelection: String? = null, inspected: Environment? = null) {
    var page by remember { mutableStateOf(1) }
    var selected by remember(initialSelection) { mutableStateOf(initialSelection) }
    Row {
        CharactersScreen(page = page, onPage = { page = it }, onSelect = { selected = it }, modifier = Modifier.width(360.dp).fillMaxHeight())
        VerticalDivider()
        Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
            val id = selected
            if (id == null) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Select a character.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                CharacterScreen(id = id)
            }
        }
        if (inspected != null) {
            VerticalDivider()
            StoreInspector(inspected, modifier = Modifier.width(320.dp).fillMaxHeight())
        }
    }
}
