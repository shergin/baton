package baton.anilist

import androidx.compose.runtime.snapshots.Snapshot
import baton.Environment
import baton.Hold
import baton.Json
import baton.Phase
import baton.Spec
import baton.Store
import baton.Transport
import baton.Variable
import baton.dump
import baton.testing.RecordedTransport
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * A list recorded from AniList: the documents in `AniListDocuments.kt` read
 * through the responses under `spec/anilist/`, as
 * `swift/Tests/BatonAniListTests/AniListTests.swift` reads them, against the
 * same dump.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AniListTests {
    /** A response recorded from AniList, by file name under `spec/anilist/`. */
    private fun recorded(name: String): ByteArray = Spec.bytes("anilist/$name")

    /** A transport that answers each chunk of the list with its recording and the save of entry 991 with its shaped response. */
    private fun aniListTransport(): RecordedTransport = RecordedTransport { request ->
        when {
            request.operationName == SaveEntryMutation.name -> recorded("save-entry-991-progress.json")
            request.operationName != ListQuery.name -> null
            else -> (request.variables["chunk"] as? Variable.Int)?.value?.takeIf { it <= 2L }?.let { recorded("list-anime-chunk-$it.json") }
        }
    }

    /** The two chunks as the list's screen asks for them: one handle a chunk. */
    private val chunks = listOf(ListQuery(userId = 0, mediaType = MediaType.ANIME, chunk = 1), ListQuery(userId = 0, mediaType = MediaType.ANIME, chunk = 2))

    /** An environment over [transport] on the test's scheduler, committing and ingesting on one test dispatcher, with no log. */
    private fun TestScope.environment(transport: Transport): Environment {
        val dispatcher = StandardTestDispatcher(testScheduler)
        return Environment(transport, null, Store(), dispatcher, dispatcher).also { it.log = null }
    }

    /** The two chunks, fetched and held as a screen holds them. */
    private suspend fun TestScope.listScreen(environment: Environment): Pair<List<ListQuery.Data>, List<Hold>> {
        val readings = ArrayList<ListQuery.Data>()
        val holds = ArrayList<Hold>()
        for (chunk in chunks) {
            val handle = environment.handle(chunk)
            holds.add(handle.retain())
            runCurrent()
            handle.settle()
            readings.add(assertIs<Phase.Ready<ListQuery.Data>>(handle.phase, "chunk ${chunk.chunk} arrives").data)
        }
        return readings to holds
    }

    /** The entries of one chunk's reading, in the order the response lists them. */
    private fun entries(data: ListQuery.Data): List<EntryRow_mediaList> =
        data.MediaListCollection?.lists.orEmpty().flatMap { group -> group.entries.orEmpty().map { it.entryRow } }

    /** The entries of the recording, from the response's own JSON: what each lens must read. */
    @Suppress("UNCHECKED_CAST")
    private fun recordedEntries(chunk: Int): List<Map<String, Any?>> {
        val response = Json.parse(recorded("list-anime-chunk-$chunk.json").decodeToString()) as Map<String, Any?>
        val collection = (response["data"] as Map<String, Any?>)["MediaListCollection"] as Map<String, Any?>
        return (collection["lists"] as List<Map<String, Any?>>).flatMap { it["entries"] as List<Map<String, Any?>> }
    }

    @Test
    fun `two chunks of 500 entries normalize into the records the dump freezes`() = runTest {
        val environment = environment(aniListTransport())
        val (_, holds) = listScreen(environment)

        val expected = File(Spec.directory, "anilist/list-anime.store.json").readText()
        val dump = environment.store.dump()
        val line = dump.lines().zip(expected.lines()).indexOfFirst { (store, file) -> store != file }
        assertTrue(dump == expected, "the store differs from list-anime.store.json at line ${line + 1}")
        holds.forEach { it.release() }
        environment.end()
    }

    @Test
    fun `every entry reads through the lenses what the response wrote, its media one record per type and id`() = runTest {
        val environment = environment(aniListTransport())
        val (readings, holds) = listScreen(environment)

        for ((index, data) in readings.withIndex()) {
            val read = entries(data)
            val wrote = recordedEntries(index + 1)
            assertEquals(500, read.size)
            assertEquals(wrote.size, read.size)
            assertEquals(true, data.MediaListCollection?.hasNextChunk)
            for ((entry, json) in read.zip(wrote)) {
                @Suppress("UNCHECKED_CAST")
                val media = json["media"] as Map<String, Any?>
                @Suppress("UNCHECKED_CAST")
                val title = media["title"] as Map<String, Any?>
                assertEquals((json["id"] as Long).toInt(), entry.id)
                assertEquals(json["status"], entry.status?.scalarText)
                assertEquals((json["progress"] as Long?)?.toInt(), entry.progress)
                assertEquals((json["score"] as Number?)?.toDouble(), entry.score)
                assertEquals(json["notes"], entry.notes)
                assertNull(entry.customLists)
                assertEquals((json["updatedAt"] as Long?)?.toInt(), entry.updatedAt)
                assertEquals((media["id"] as Long).toInt(), entry.media?.id)
                val card = assertNotNull(entry.media?.mediaCard)
                assertEquals(media["status"], card.status?.scalarText)
                assertEquals(title["romaji"], card.title?.romaji)
                assertEquals(title["native"], card.title?.native)
                @Suppress("UNCHECKED_CAST")
                assertEquals((media["coverImage"] as Map<String, Any?>)["color"], card.coverImage?.color)
                assertEquals(media["siteUrl"], card.siteUrl)
                @Suppress("UNCHECKED_CAST")
                val airing = media["nextAiringEpisode"] as Map<String, Any?>?
                assertEquals((airing?.get("airingAt") as Long?)?.toInt(), card.nextAiringEpisode?.airingAt)
            }
        }
        // Entry 1 is `MediaList:1`, and the list also holds Cowboy Bebop,
        // `Media:1`: identity is per type, so the two are two records.
        val all = readings.flatMap(::entries)
        assertEquals(1, all.first().id)
        assertTrue(all.any { it.media?.id == 1 })
        holds.forEach { it.release() }
        environment.end()
    }

    @Test
    fun `an entry asked for by MediaList(id) is answered by the lookup from the list's records, with no request`() = runTest {
        val transport = aniListTransport()
        val environment = environment(transport)
        val (_, holds) = listScreen(environment)
        val sent = transport.requests.size

        val handle = environment.handle(EntryQuery(id = 991))
        val held = handle.retain()
        val data = assertIs<Phase.Ready<EntryQuery.Data>>(handle.phase, "the lookup answers from the store").data
        val entry = assertNotNull(data.MediaList?.entryRow)
        assertEquals(MediaListStatus.PAUSED, entry.status)
        assertEquals(248, entry.progress)
        assertEquals("ONE PIECE", entry.media?.mediaCard?.title?.romaji)
        assertEquals(1181, entry.media?.mediaCard?.nextAiringEpisode?.episode)
        runCurrent()
        assertEquals(sent, transport.requests.size)
        held.release()
        holds.forEach { it.release() }
        environment.end()
    }

    @Test
    fun `a save that changes one field notifies the list's row and the detail that read it, and no other body`() = runTest {
        val environment = environment(aniListTransport())
        val (readings, holds) = listScreen(environment)
        val handle = environment.handle(EntryQuery(id = 991))
        val held = handle.retain()
        val shown = assertNotNull(assertIs<Phase.Ready<EntryQuery.Data>>(handle.phase).data.MediaList?.entryRow)

        // Every row's body reads its entry whole, the detail's body reads the
        // entry, and one more body reads entry 991's status alone.
        val bodies = LinkedHashMap<String, Set<Any>>()
        for (row in readings.flatMap(::entries)) bodies["row ${row.id}"] = statesRead { read(row) }
        bodies["detail"] = statesRead { read(shown) }
        bodies["status"] = statesRead { shown.status }
        val told = ArrayList<String>()
        val observer = Snapshot.registerApplyObserver { changed, _ ->
            for ((name, states) in bodies) if (changed.any { it in states }) told.add(name)
        }
        try {
            val saved = async { environment.mutate(SaveEntryMutation(id = 991, progress = 249)) }
            runCurrent()
            assertEquals(249, saved.await().SaveMediaListEntry?.entryRow?.progress)
            Snapshot.sendApplyNotifications()
        } finally {
            observer.dispose()
        }
        assertEquals(listOf("detail", "row 991"), told.sorted())
        assertEquals(249, shown.progress)
        held.release()
        holds.forEach { it.release() }
        environment.end()
    }

    /** The states [read] registers in a snapshot that observes its reads. */
    private fun statesRead(read: () -> Unit): Set<Any> {
        val states = HashSet<Any>()
        val snapshot = Snapshot.takeSnapshot { states.add(it) }
        try {
            snapshot.enter(read)
        } finally {
            snapshot.dispose()
        }
        return states
    }
}

/** What a row's body reads of an entry: every field of the row's fragment and of its media's card, folded into a number so nothing is skipped. */
internal fun read(entry: EntryRow_mediaList): Int {
    var sink = entry.id
    sink += entry.status?.scalarText?.length ?: 0
    sink += entry.progress ?: 0
    sink += entry.progressVolumes ?: 0
    sink += (entry.score ?: 0.0).toInt()
    sink += entry.repeat ?: 0
    sink += entry.priority ?: 0
    sink += entry.notes?.length ?: 0
    sink += if (entry.private == true) 1 else 0
    sink += if (entry.hiddenFromStatusLists == true) 1 else 0
    sink += entry.customLists?.length ?: 0
    sink += (entry.startedAt?.year ?: 0) + (entry.startedAt?.month ?: 0) + (entry.startedAt?.day ?: 0)
    sink += (entry.completedAt?.year ?: 0) + (entry.completedAt?.month ?: 0) + (entry.completedAt?.day ?: 0)
    sink += entry.updatedAt ?: 0
    val media = entry.media ?: return sink
    val card = media.mediaCard
    sink += card.id + (card.idMal ?: 0)
    sink += card.type?.scalarText?.length ?: 0
    sink += card.format?.scalarText?.length ?: 0
    sink += card.status?.scalarText?.length ?: 0
    sink += (card.episodes ?: 0) + (card.chapters ?: 0) + (card.volumes ?: 0) + (card.duration ?: 0)
    sink += card.season?.scalarText?.length ?: 0
    sink += card.seasonYear ?: 0
    sink += card.countryOfOrigin?.length ?: 0
    sink += if (card.isAdult == true) 1 else 0
    sink += card.siteUrl?.length ?: 0
    sink += card.title?.romaji?.length ?: 0
    sink += card.title?.english?.length ?: 0
    sink += card.title?.native?.length ?: 0
    sink += card.title?.userPreferred?.length ?: 0
    sink += card.coverImage?.large?.length ?: 0
    sink += card.coverImage?.color?.length ?: 0
    card.nextAiringEpisode?.let { sink += it.id + it.episode + it.airingAt }
    return sink
}
