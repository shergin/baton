package baton.sample

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Density
import androidx.compose.ui.use
import baton.Environment
import baton.LocalBaton
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.swing.Swing
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Image

/**
 * Renders the sample's screens to PNG files without a window, for the
 * README and for a machine with no screen: the composition the app shows,
 * over the live API, drawn by Skia into an image once the data has
 * arrived. `gradle :samples:desktop:screenshot` writes
 * `build/screenshots/characters.png`, `detail.png` and `inspector.png`, the
 * last with the store inspector's pane.
 */
fun main(arguments: Array<String>) {
    val directory = File(arguments.firstOrNull() ?: "build/screenshots").apply { mkdirs() }
    // The store belongs to the thread that made it, and Compose's main
    // dispatcher on the desktop is the event thread, so the rendering runs
    // there from start to end.
    runBlocking(Dispatchers.Swing) {
        val environment = Environment("https://rickandmortyapi.com/graphql")
        val selection = mutableStateOf<String?>(null)
        val inspected = mutableStateOf<Environment?>(null)
        ImageComposeScene(width = 1280, height = 720, density = Density(1f), coroutineContext = coroutineContext).use { scene ->
            scene.setContent {
                SampleTheme {
                    Surface(modifier = Modifier.fillMaxSize()) {
                        CompositionLocalProvider(LocalBaton provides environment) {
                            Characters(initialSelection = selection.value, inspected = inspected.value)
                        }
                    }
                }
            }
            // The list fetches once, the avatars load off the event thread and
            // the frames settle; a few seconds cover the public API, which
            // rate-limits a burst, so everything is fetched once.
            repeat(60) { scene.render(); delay(100) }
            write(scene.render(), File(directory, "characters.png"))
            selection.value = "1"
            repeat(60) { scene.render(); delay(100) }
            write(scene.render(), File(directory, "detail.png"))
            inspected.value = environment
            repeat(10) { scene.render(); delay(100) }
            write(scene.render(), File(directory, "inspector.png"))
        }
        environment.end()
        println("wrote characters.png, detail.png and inspector.png in $directory")
    }
}

private fun write(image: Image, file: File) {
    val bytes = image.encodeToData(EncodedImageFormat.PNG)?.bytes ?: error("could not encode ${file.name}")
    file.writeBytes(bytes)
}
