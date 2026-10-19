package baton.anilist

import androidx.compose.runtime.snapshotFlow
import baton.Environment
import baton.OperationHandle
import baton.Phase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** What the model derives from one entry: a value, so two readings compare. */
data class Entry(val id: Int, val status: MediaListStatus?, val progress: Int?, val title: String?, val nextEpisodeAt: Int?)

/**
 * A model that derives one value from every entry of a list fetched in
 * chunks, each chunk an operation value with its handle: the shape of the
 * derived-state recipe's whole operation. Made, and its scope run, on
 * the store's thread.
 */
class ListModel(environment: Environment, scope: CoroutineScope, userId: Int, chunks: Int) {
    private val handles = (1..chunks).map { environment.handle(ListQuery(userId = userId, mediaType = MediaType.ANIME, chunk = it)) }
    private val holds = handles.map { it.retain() }

    // The first reading, untracked and in this call: a handle the image
    // answered is ready before any flow starts.
    private val readings = handles.map(::read).toMutableList()
    private val derived = MutableStateFlow(readings.flatten())

    /** The entries of every chunk, in order: the derived value. */
    val entries: StateFlow<List<Entry>> = derived

    // One flow a handle, so a change in one chunk re-reads that chunk.
    private val collection = scope.launch {
        handles.forEachIndexed { index, handle ->
            launch { snapshotFlow { read(handle) }.collect { apply(it, index) } }
        }
    }

    /** Applies a chunk's reading only when it differs from the last, so the flows' first readings, equal to the untracked one, change nothing. */
    private fun apply(reading: List<Entry>, index: Int) {
        if (reading == readings[index]) return
        readings[index] = reading
        derived.value = readings.flatten()
    }

    fun close() {
        collection.cancel()
        holds.forEach { it.release() }
    }
}

/** What the derived value needs of one chunk: five fields an entry, not the row's whole fragment, since every field read is registered. */
private fun read(handle: OperationHandle<ListQuery.Data>): List<Entry> {
    val phase = handle.phase as? Phase.Ready ?: return emptyList()
    return phase.data.MediaListCollection?.lists.orEmpty().flatMap { group ->
        group.entries.orEmpty().map { entry ->
            val row = entry.entryRow
            val card = row.media?.mediaCard
            Entry(row.id, row.status, row.progress, card?.title?.userPreferred, card?.nextAiringEpisode?.airingAt)
        }
    }
}
