package baton.macro

import androidx.tracing.Trace

/**
 * The trace sections both measured apps emit under the same names, which
 * the macrobenchmark reads with `TraceSectionMetric`: asynchronous
 * sections, since each begins on one thread and ends on another. A section
 * already open is not begun again, and one not open is not ended.
 */
object Sections {
    /** From the last byte of a characters page's response, written by the fixed server, to the first draw of that page's list. */
    const val LIST_RESPONSE_TO_FRAME = "ListResponseToFrame"

    /** From the tap on a row to the first draw of the character's header. */
    const val DETAIL_TAP_TO_FRAME = "DetailTapToFrame"

    /** From the tap on Next to the first draw of the next page's list. */
    const val PAGE_TURN_TO_FRAME = "PageTurnToFrame"

    private const val COOKIE = 0x6261
    private val open = HashSet<String>()

    fun begin(name: String) {
        synchronized(open) { if (open.add(name)) Trace.beginAsyncSection(name, COOKIE) }
    }

    fun end(name: String) {
        synchronized(open) { if (open.remove(name)) Trace.endAsyncSection(name, COOKIE) }
    }

    /** A page's list drew for the first time: the response's and the page turn's sections end. */
    fun listDrawn() {
        end(LIST_RESPONSE_TO_FRAME)
        end(PAGE_TURN_TO_FRAME)
    }
}
