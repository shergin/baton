package baton.sample

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import baton.Phase
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.jetbrains.skia.Image as SkiaImage

/** Loading, failure and ready, the same everywhere: the phase's three cases. */
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

/**
 * A character's picture, fetched once per address off the event thread and
 * kept for the process, so a scroll back does not fetch it again; a plain
 * square until it arrives. The cache is read and written on the event
 * thread, where compositions run.
 */
@Composable
fun Avatar(url: String?, size: Int) {
    val image by produceState(url?.let(avatars::get), url) {
        if (value != null || url == null) return@produceState
        val fetched = withContext(Dispatchers.IO) {
            runCatching { SkiaImage.makeFromEncoded(URI(url).toURL().readBytes()).toComposeImageBitmap() }.getOrNull()
        }
        if (fetched != null) avatars[url] = fetched
        value = fetched
    }
    val shape = RoundedCornerShape((size / 5).dp)
    val modifier = Modifier.size(size.dp).clip(shape).background(MaterialTheme.colorScheme.surfaceVariant)
    val loaded = image
    if (loaded == null) {
        Box(modifier)
    } else {
        Image(loaded, contentDescription = null, modifier = modifier, contentScale = ContentScale.Crop)
    }
}

private val avatars = HashMap<String, ImageBitmap>()
