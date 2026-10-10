package baton.macro

import androidx.tracing.Trace

/**
 * The trace sections both measured apps emit under the same names, which
 * the macrobenchmark reads with `TraceSectionMetric`: asynchronous
 * sections, since each begins on one thread and ends on another. A section
 * already open is not begun again, and one not open is not ended.
 */
object Sections {
    /**
     * From the first byte of a characters page's response, as the fixed
     * server starts writing it, to the first draw of that page's list: the
     * transfer, the parse, the store and the frame, whether a client reads
     * the body as it arrives or once it is whole.
     */
    const val LIST_RESPONSE_TO_FRAME = "ListResponseToFrame"

    /**
     * From the last byte of the same response, once the server's write
     * returns, to the same draw. A client that parses as it reads has done
     * most of its parse by then, since the loopback socket's buffer holds
     * back the server's writes until the client reads.
     */
    const val LIST_LAST_BYTE_TO_FRAME = "ListLastByteToFrame"

    /**
     * From the last byte of a characters page's response to the data in
     * the store: Baton's commit of the page, on the main thread after the
     * ingest; Apollo's emission of the response, after its cache write.
     * The last byte's section split in two at the store, with the next.
     */
    const val LIST_LAST_BYTE_TO_STORE = "ListLastByteToStore"

    /** From the data in the store to the first draw of the list: the recomposition, the layout and the frame. */
    const val LIST_STORE_TO_FRAME = "ListStoreToFrame"

    /** The construction of the app's client, Baton's environment and store or Apollo's client and cache, on the main thread. */
    const val CLIENT_SETUP = "ClientSetup"

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

    /**
     * A page's data reached the store: the last byte's section to the store
     * ends and the store's to the frame begins, when a page is on its way;
     * a commit or an emission of anything else does nothing here.
     */
    fun stored() {
        synchronized(open) {
            if (!open.remove(LIST_LAST_BYTE_TO_STORE)) return
            Trace.endAsyncSection(LIST_LAST_BYTE_TO_STORE, COOKIE)
            if (open.add(LIST_STORE_TO_FRAME)) Trace.beginAsyncSection(LIST_STORE_TO_FRAME, COOKIE)
        }
    }

    /** A page's list drew for the first time: the response's, the store's and the page turn's sections end. */
    fun listDrawn() {
        end(LIST_RESPONSE_TO_FRAME)
        end(LIST_LAST_BYTE_TO_FRAME)
        end(LIST_LAST_BYTE_TO_STORE)
        end(LIST_STORE_TO_FRAME)
        end(PAGE_TURN_TO_FRAME)
    }
}
