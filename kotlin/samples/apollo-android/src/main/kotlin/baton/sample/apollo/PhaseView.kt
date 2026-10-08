package baton.sample.apollo

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import com.apollographql.apollo.ApolloClient
import com.apollographql.apollo.api.ApolloResponse
import com.apollographql.apollo.api.Query
import com.apollographql.apollo.exception.CacheMissException
import com.apollographql.cache.normalized.watch
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The client the screens query, provided by the activity. */
val LocalApollo = staticCompositionLocalOf<ApolloClient> { error("no ApolloClient provided") }

/** Material 3's light or dark colors, as the system's appearance is. */
@Composable
fun SampleTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme(), content = content)
}

/**
 * A query's latest response, as Apollo's documentation has Compose read
 * it: the call's `watch()` flow collected as state, which emits the cached
 * data, or the network's when the cache misses, and again whenever the
 * cache changes what the query read. Null until the first response; a
 * changed query or a retry starts again from null.
 */
class Watched<D : Query.Data>(val response: ApolloResponse<D>?, val retry: () -> Unit)

@Composable
fun <D : Query.Data> watchQuery(query: Query<D>): Watched<D> {
    val client = LocalApollo.current
    var attempt by remember(query) { mutableIntStateOf(0) }
    val flow = remember(client, query, attempt) { client.query(query).watch() }
    val response = key(flow) { flow.collectAsState(initial = null).value }
    return Watched(response, retry = { attempt++ })
}

/** Loading, failure and ready, the same everywhere: the Baton sample's three cases over a response. */
@Composable
fun <D : Query.Data> PhaseView(watched: Watched<D>, content: @Composable (D) -> Unit) {
    val response = watched.response
    val data = response?.data
    when {
        data != null -> content(data)
        response == null || response.exception is CacheMissException ->
            Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        else -> Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        ) {
            Text("Could not load", style = MaterialTheme.typography.titleMedium)
            val error = response.exception?.message ?: response.errors?.firstOrNull()?.message ?: "no data"
            Text(error, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = watched.retry) { Text("Retry") }
        }
    }
}

/**
 * What a measured launch sets, on the main thread: where an avatar is
 * fetched from, and what the screens report when a page's list or a
 * character's header first draws; the Baton sample's `Measurement`.
 */
object Measurement {
    var avatarAddress: (String) -> String = { it }
    var listDrawn: (page: Int) -> Unit = {}
    var detailDrawn: () -> Unit = {}
}

/** Calls [action] in the first draw of this element after [key] changes, once its content is drawn. */
@Composable
internal fun Modifier.onFirstDraw(key: Any?, action: () -> Unit): Modifier {
    val drawn = remember(key) { BooleanArray(1) }
    return drawWithContent {
        drawContent()
        if (!drawn[0]) {
            drawn[0] = true
            action()
        }
    }
}

/**
 * A character's picture, fetched once per address off the main thread and
 * kept for the process, so a scroll back does not fetch it again; a plain
 * square until it arrives. The cache is read and written on the main
 * thread, where compositions run.
 */
@Composable
fun Avatar(url: String?, size: Int) {
    val image by produceState(url?.let(avatars::get), url) {
        if (value != null || url == null) return@produceState
        val fetched = fetchImage(Measurement.avatarAddress(url))
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

/** The image at [url], fetched over `java.net` and decoded by `BitmapFactory` off the main thread; null when either fails. */
private suspend fun fetchImage(url: String): ImageBitmap? = withContext(Dispatchers.IO) {
    runCatching {
        val bytes = URI(url).toURL().readBytes()
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
    }.getOrNull()
}
