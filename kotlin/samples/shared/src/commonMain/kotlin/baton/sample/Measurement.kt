package baton.sample

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent

/**
 * What an app that measures the screens sets, on the main thread: where an
 * avatar is fetched from, and what the screens report when a page's list or
 * a character's header first draws. Unset, an avatar comes from its own
 * address and nothing is reported. `kotlin/benchmarks/macro` reads the
 * reports as trace sections.
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
