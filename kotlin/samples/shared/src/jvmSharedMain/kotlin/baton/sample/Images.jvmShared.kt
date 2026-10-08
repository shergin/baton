package baton.sample

import androidx.compose.ui.graphics.ImageBitmap
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal actual suspend fun fetchImage(url: String): ImageBitmap? = withContext(Dispatchers.IO) {
    runCatching { decodeImage(URI(url).toURL().readBytes()) }.getOrNull()
}

/** An encoded image's bitmap, by the platform's decoder; null for bytes it cannot read. */
internal expect fun decodeImage(bytes: ByteArray): ImageBitmap?
