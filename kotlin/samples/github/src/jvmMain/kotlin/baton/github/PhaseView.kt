package baton.github

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import baton.Phase

/**
 * Loading, failure and ready, the same everywhere: the phase's three cases.
 * Copied from the desktop sample; a module the samples share is a later step.
 */
@Composable
fun <Data> PhaseView(phase: Phase<Data>, retry: () -> Unit, content: @Composable (Data) -> Unit) {
    when (phase) {
        is Phase.Ready -> content(phase.data)
        Phase.Loading -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        is Phase.Failed -> Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        ) {
            Text("Could not load", style = MaterialTheme.typography.titleMedium)
            Text(phase.error.message ?: phase.error.toString(), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = retry) { Text("Retry") }
        }
    }
}
