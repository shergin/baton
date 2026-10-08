package baton.github

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import baton.Environment
import baton.LocalBaton
import baton.Persistence
import baton.Store
import kotlinx.coroutines.launch

/**
 * The sample on GitHub's API: a repository with a star toggle and its open
 * issues a page at a time, beside an issue with its comments and a
 * composer. Reads, writes with optimistic responses, connections appended to
 * by a mutation's edge, interfaces, and a lookup by id, against a schema of
 * about 1,800 definitions. Needs a personal access token, which stays in
 * memory:
 *
 *     GITHUB_TOKEN=$(gh auth token) gradle :samples:github:run
 */
fun main() = application {
    Window(onCloseRequest = ::exitApplication, title = "GitHub Triage", state = rememberWindowState(size = DpSize(1100.dp, 760.dp))) {
        MaterialTheme {
            Surface(modifier = Modifier.fillMaxSize()) {
                GitHubTriage()
            }
        }
    }
}

/** Sign-in until a token is given, then the triage over an environment that sends it. */
@Composable
fun GitHubTriage() {
    // The token lives in this state alone: nothing writes it to disk.
    var token by remember { mutableStateOf<String?>(null) }
    val signedIn = token
    if (signedIn == null) {
        SignIn(initialToken = System.getenv("GITHUB_TOKEN").orEmpty(), onSignIn = { token = it })
    } else {
        SignedIn(signedIn, onSignedOut = { token = null })
    }
}

/** A token field, prefilled from `GITHUB_TOKEN` when it is set. */
@Composable
private fun SignIn(initialToken: String, onSignIn: (String) -> Unit) {
    var token by remember { mutableStateOf(initialToken) }
    Column(
        modifier = Modifier.fillMaxSize().padding(48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Text("Sign in to GitHub", style = MaterialTheme.typography.headlineSmall)
        Text(
            "A personal access token with the repo scope, for example from `gh auth token`. It is kept in memory and sent to api.github.com alone.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedTextField(
            value = token,
            onValueChange = { token = it },
            label = { Text("Token") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            modifier = Modifier.width(480.dp),
        )
        Button(onClick = { onSignIn(token.trim()) }, enabled = token.isNotBlank()) { Text("Sign in") }
    }
}

/**
 * The environment of one sign-in, made in the composition on the event
 * thread the store belongs to. The store keeps its image in the user's
 * cache directory under the schema's digest, so a relaunch renders before
 * the network answers. Sign-out ends the environment, which cancels what it
 * started and closes the image, removes the image's file, and forgets the
 * token last.
 */
@Composable
private fun SignedIn(token: String, onSignedOut: () -> Unit) {
    val environment = remember(token) {
        Environment(
            "https://api.github.com/graphql",
            headers = mapOf("Authorization" to "Bearer $token"),
            store = Store(persistence = Persistence.named("GitHubTriage", version = Types.schemaDigest)),
        )
    }
    val scope = rememberCoroutineScope()
    CompositionLocalProvider(LocalBaton provides environment) {
        Triage(
            onSignOut = {
                scope.launch {
                    environment.end()
                    environment.store.persistence?.removeAll()
                    onSignedOut()
                }
            },
        )
    }
}

/** The repository named in the bar, its issues, and the issue selected in them. */
@Composable
fun Triage(onSignOut: () -> Unit, initialOwner: String = "octocat", initialName: String = "Hello-World") {
    var ownerField by remember { mutableStateOf(initialOwner) }
    var nameField by remember { mutableStateOf(initialName) }
    var shown by remember { mutableStateOf(initialOwner to initialName) }
    var selected by remember { mutableStateOf<String?>(null) }
    Column {
        Row(
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(ownerField, { ownerField = it }, label = { Text("Owner") }, singleLine = true, modifier = Modifier.width(200.dp))
            OutlinedTextField(nameField, { nameField = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.width(240.dp))
            Button(
                onClick = {
                    shown = ownerField.trim() to nameField.trim()
                    selected = null
                },
                enabled = ownerField.isNotBlank() && nameField.isNotBlank(),
            ) { Text("Open") }
            Box(modifier = Modifier.weight(1f))
            TextButton(onClick = onSignOut) { Text("Sign out") }
        }
        HorizontalDivider()
        Row {
            val (owner, name) = shown
            RepositoryScreen(owner, name, onSelect = { selected = it }, modifier = Modifier.width(440.dp).fillMaxHeight())
            VerticalDivider()
            val id = selected
            if (id == null) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Select an issue.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                IssueScreen(id, modifier = Modifier.fillMaxSize())
            }
        }
    }
}
