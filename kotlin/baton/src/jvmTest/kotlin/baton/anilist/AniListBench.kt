package baton.anilist

import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import baton.Anchor
import baton.Answer
import baton.ChangeSet
import baton.Environment
import baton.Ingest
import baton.Owner
import baton.Persistence
import baton.Phase
import baton.Spec
import baton.Store
import baton.check
import baton.testing.SilentTransport
import java.io.File
import java.util.UUID
import kotlin.coroutines.ContinuationInterceptor
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * The bench of the list recorded under `spec/anilist/` on the JVM, the
 * Kotlin twin of the AniList section of `swift/Benchmarks`:
 * `gradle :baton:runAniListBench`. Every measurement runs on the thread
 * that made its store, after as many warm-up rounds as it samples, and
 * prints the best and the median.
 */
fun main(arguments: Array<String>) {
    if (arguments.size == 2 && arguments[0].startsWith("--launch")) {
        launch(arguments[1], opened = arguments[0] == "--launch-opened")
        return
    }
    val machine = "the JVM ${System.getProperty("java.vm.name")} ${System.getProperty("java.version")}, " +
        "${System.getProperty("os.name")} ${System.getProperty("os.version")} ${System.getProperty("os.arch")}"
    println("Baton AniList bench on $machine")
    AniListBench().run()
}

/** The two chunks of the recording, as a screen asks for them: one operation value a chunk. */
private val chunks = listOf(ListQuery(userId = 0, mediaType = MediaType.ANIME, chunk = 1), ListQuery(userId = 0, mediaType = MediaType.ANIME, chunk = 2))

/** The recorded responses, by chunk. */
private val responses = listOf(Spec.bytes("anilist/list-anime-chunk-1.json"), Spec.bytes("anilist/list-anime-chunk-2.json"))

/** A store holding both chunks, committed in order, with a lens over each chunk's root. */
private fun listStore(persistence: Persistence? = null): Pair<Store, List<ListQuery.Data>> {
    val store = Store(persistence)
    val readings = chunks.zip(responses).map { (chunk, bytes) ->
        store.commit(Ingest.normalize(bytes, store.resolve(ListQuery.plan, chunk.variables), Store.ROOT_KEY))
        ListQuery.Data(Anchor(store.root, Owner.reading(chunk.variables, store)))
    }
    return store to readings
}

/** The entries of one chunk's reading, in the order the response lists them. */
private fun entries(data: ListQuery.Data): List<EntryRow_mediaList> =
    data.MediaListCollection?.lists.orEmpty().flatMap { group -> group.entries.orEmpty().map { it.entryRow } }

/** A reading over every entry of the chunks' data, the shape a model that derives one value from the whole list runs. */
private fun readList(readings: List<ListQuery.Data>): Int = readings.sumOf { data -> entries(data).sumOf { readEntry(it, Fields()) } }

/** The slots a reading read. */
private class Fields {
    var count = 0
}

/** What a row's body reads of an entry: every field of the row's fragment and of its media's card, each slot once. */
private fun readEntry(entry: EntryRow_mediaList, fields: Fields): Int {
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
    sink += entry.updatedAt ?: 0
    fields.count += 12
    entry.startedAt?.let { sink += (it.year ?: 0) + (it.month ?: 0) + (it.day ?: 0); fields.count += 3 }
    entry.completedAt?.let { sink += (it.year ?: 0) + (it.month ?: 0) + (it.day ?: 0); fields.count += 3 }
    fields.count += 3
    val card = entry.media?.mediaCard ?: return sink
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
    fields.count += 14
    card.title?.let {
        sink += (it.romaji?.length ?: 0) + (it.english?.length ?: 0) + (it.native?.length ?: 0) + (it.userPreferred?.length ?: 0)
        fields.count += 4
    }
    card.coverImage?.let { sink += (it.large?.length ?: 0) + (it.color?.length ?: 0); fields.count += 2 }
    card.nextAiringEpisode?.let { sink += it.id + it.episode + it.airingAt; fields.count += 3 }
    fields.count += 3
    return sink
}

/** The reading the derived-state recipe's model takes of one chunk: five values an entry, seven slots, where [readList] reads forty-four. */
private fun readNarrow(data: ListQuery.Data): Int = entries(data).sumOf { entry ->
    val card = entry.media?.mediaCard
    entry.id + (entry.status?.scalarText?.length ?: 0) + (entry.progress ?: 0) +
        (card?.title?.userPreferred?.length ?: 0) + (card?.nextAiringEpisode?.airingAt ?: 0)
}

/** The fields [readList] reads over [readings]. */
private fun fieldsRead(readings: List<ListQuery.Data>): Int {
    val fields = Fields()
    for (data in readings) for (entry in entries(data)) readEntry(entry, fields)
    return fields.count
}

/** The states [read] registers in a snapshot that observes its reads, as `snapshotFlow` reads its block. */
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

private class AniListBench {
    private var sink = 0

    private fun format(nanoseconds: Double): String = when {
        nanoseconds >= 1_000_000 -> "%8.2f ms".format(nanoseconds / 1_000_000)
        nanoseconds >= 1_000 -> "%8.2f µs".format(nanoseconds / 1_000)
        else -> "%8.1f ns".format(nanoseconds)
    }

    private fun report(label: String, samples: List<Long>, ops: Int) {
        val sorted = samples.sorted()
        println("  ${label.padEnd(64)} best ${format(sorted.first().toDouble() / ops)}   median ${format(sorted[sorted.size / 2].toDouble() / ops)}")
    }

    /** Times [body] alone, [iterations] times after as many warm-up rounds; [setup] runs before each round, off the clock. */
    private fun measure(label: String, iterations: Int, ops: Int = 1, setup: () -> Unit = {}, body: () -> Unit) {
        val samples = ArrayList<Long>()
        repeat(iterations * 2) { round ->
            setup()
            val start = System.nanoTime()
            body()
            val elapsed = System.nanoTime() - start
            if (round >= iterations) samples.add(elapsed)
        }
        report(label, samples, ops)
    }

    /** Times a step that returns the nanoseconds it wants counted, after as many warm-up rounds. */
    private fun measureEach(label: String, iterations: Int, warmUp: Int = iterations, body: () -> Long) {
        repeat(warmUp) { body() }
        report(label, List(iterations) { body() }, 1)
    }

    fun run() {
        println("  responses: ${responses[0].size} and ${responses[1].size} bytes, 500 entries each")
        val planned = Store()
        val plans = chunks.map { planned.resolve(ListQuery.plan, it.variables) }
        measure("ingest of a chunk of 500 entries, bytes -> change set, per chunk", iterations = 30, ops = 2) {
            for ((bytes, plan) in responses.zip(plans)) Ingest.normalize(bytes, plan, Store.ROOT_KEY)
        }
        var fresh = Store()
        var changes: List<ChangeSet> = emptyList()
        measure("commit of both chunks into an empty store", iterations = 20, setup = {
            fresh = Store()
            changes = chunks.zip(responses).map { (chunk, bytes) -> Ingest.normalize(bytes, fresh.resolve(ListQuery.plan, chunk.variables), Store.ROOT_KEY) }
        }) {
            for (change in changes) fresh.commit(change)
        }
        println("    records after both chunks: ${fresh.count}")

        // The reading a model that derives one value from the whole list
        // runs, over every field of every entry. A slot's channel is made at
        // its first read, so a store's first reading pays for making them
        // and a later one does not; a read-observing snapshot is what
        // `snapshotFlow` reads its block in.
        val (store, readings) = listStore()
        val fields = fieldsRead(readings)
        println("  a reading of the list: $fields fields over 1,000 entries, ${fields / 1_000} an entry")
        var first = readings
        measure("the first reading of a store, untracked, making the channels", iterations = 20, setup = { first = listStore().second }) {
            sink += readList(first)
        }
        measure("the reading, untracked, the whole list", iterations = 50) { sink += readList(readings) }
        measure("the reading, untracked, per field", iterations = 50, ops = fields) { sink += readList(readings) }
        measure("the reading in one read-observing snapshot, the whole list", iterations = 20) {
            statesRead { sink += readList(readings) }
        }
        measure("the same, per field", iterations = 20, ops = fields) {
            statesRead { sink += readList(readings) }
        }
        measure("one chunk's reading in its own snapshot, 500 entries", iterations = 20) {
            statesRead { sink += readList(listOf(readings[1])) }
        }
        measure("one chunk's reading of five values an entry, its own snapshot", iterations = 20) {
            statesRead { sink += readNarrow(readings[1]) }
        }
        val thread = Thread.currentThread()
        measureEach("the reading through snapshotFlow, made to its first value", iterations = 20) {
            runBlocking {
                check(Thread.currentThread() == thread)
                val start = System.nanoTime()
                sink += snapshotFlow { readList(readings) }.first()
                System.nanoTime() - start
            }
        }

        // The composition the derived-state recipe gives for a whole
        // operation: one `snapshotFlow` a chunk's handle, so a change in one
        // chunk re-reads that chunk, timed from the commit of a one-field
        // save of an entry in the second chunk to that chunk's reading
        // delivered.
        val save = Spec.bytes("anilist/save-entry-991-progress.json")
        val back = save.decodeToString().replace("\"progress\":249", "\"progress\":248").encodeToByteArray()
        val savePlan = store.resolve(SaveEntryMutation.plan, SaveEntryMutation(id = 991, progress = 249).variables)
        val saved = Ingest.normalize(save, savePlan, Store.MUTATION_ROOT_KEY)
        val restored = Ingest.normalize(back, savePlan, Store.MUTATION_ROOT_KEY)
        for ((label, reading) in listOf<Pair<String, () -> Int>>(
            "a one-field save, the commit to its chunk's reading delivered" to { readList(listOf(readings[1])) },
            "the same, the chunk read five values an entry" to { readNarrow(readings[1]) },
        )) {
            runBlocking {
                val delivered = Channel<Int>(Channel.UNLIMITED)
                val collector = launch { snapshotFlow { reading() }.collect { delivered.send(it) } }
                delivered.receive()
                val samples = ArrayList<Long>()
                repeat(40) { round ->
                    val start = System.nanoTime()
                    store.commit(if (round % 2 == 0) saved else restored)
                    Snapshot.sendApplyNotifications()
                    sink += delivered.receive()
                    if (round >= 20) samples.add(System.nanoTime() - start)
                }
                collector.cancel()
                report(label, samples, 1)
            }
            store.commit(restored)
            Snapshot.sendApplyNotifications()
        }

        // The save's commit with every row's body observing its entry whole
        // and a detail's body observing entry 991: the two that read
        // `progress` of that record are told, and no other.
        store.commit(restored)
        val rows = readings.flatMap(::entries)
        val lookup = EntryQuery(id = 991)
        check(store.check(store.resolve(EntryQuery.plan, lookup.variables)) != Answer.MISS) { "the lookup did not answer entry 991 from the list" }
        val detail = checkNotNull(EntryQuery.Data(Anchor(store.root, Owner.reading(lookup.variables, store))).MediaList?.entryRow)
        val bodies = (rows + detail).map { body -> statesRead { readEntry(body, Fields()) } }
        var told = 0
        val observer = Snapshot.registerApplyObserver { changed, _ -> for (states in bodies) if (changed.any { it in states }) told++ }
        measure("the save's commit, 1,000 rows and a detail observing", iterations = 20, setup = {
            store.commit(restored)
            Snapshot.sendApplyNotifications()
            told = 0
        }) {
            store.commit(saved)
            Snapshot.sendApplyNotifications()
        }
        observer.dispose()
        println("    notifications per save: $told (the row and the detail that read the entry's progress)")

        // Through the image: the write-behind of both chunks, the file's
        // size after it, and a launch in a new process to both handles ready.
        val path = File(System.getProperty("java.io.tmpdir"), "baton-bench-anilist-${UUID.randomUUID()}.sqlite").path
        try {
            val persistence = Persistence(path)
            runBlocking { persistence.flush() }
            measureEach("write-behind of both chunks, off the store's thread", iterations = 10, warmUp = 3) {
                val (written, _) = listStore(persistence)
                val start = System.nanoTime()
                runBlocking { persistence.flush() }
                val elapsed = System.nanoTime() - start
                check(written.count > 6_000)
                elapsed
            }
            runBlocking { persistence.close() }
            println("    the image after both chunks, closed: ${File(path).length()} bytes")
            measureEach("a launch: open and hydrate at once, both handles ready", iterations = 15, warmUp = 0) { launched("--launch", path) }
            measureEach("a launch: both handles ready after the image has opened", iterations = 15, warmUp = 0) { launched("--launch-opened", path) }
        } finally {
            for (suffix in listOf("", "-wal", "-shm", "-discard")) File(path + suffix).delete()
        }
        if (sink == 42) println("")
    }

    /** This program again, as a new JVM answering both chunks from the image; returns the nanoseconds it printed. */
    private fun launched(flag: String, path: String): Long {
        val java = File(System.getProperty("java.home"), "bin/java").path
        val child = ProcessBuilder(java, "-cp", System.getProperty("java.class.path"), "baton.anilist.AniListBenchKt", flag, path)
            .redirectErrorStream(true)
            .start()
        val text = child.inputStream.bufferedReader().readText()
        check(child.waitFor() == 0) { "the launch child failed: $text" }
        return text.trim().lines().last().toLong()
    }
}

/**
 * What the child process of the launch bench does: from creating the
 * image's handle to both chunks' handles ready from it, or, with [opened],
 * the handles alone once the file has opened on the writer's thread. Prints
 * nanoseconds.
 */
private fun launch(path: String, opened: Boolean) = runBlocking {
    var start = System.nanoTime()
    val persistence = Persistence(path)
    if (opened) {
        persistence.flush()
        start = System.nanoTime()
    }
    val dispatcher = coroutineContext[ContinuationInterceptor] as CoroutineDispatcher
    val environment = Environment(SilentTransport(), null, Store(persistence), dispatcher, Dispatchers.Default).also { it.log = null }
    val handles = chunks.map { environment.handle(it) }
    val holds = handles.map { it.retain() }
    val ready = handles.all { it.phase is Phase.Ready }
    val elapsed = System.nanoTime() - start
    check(ready) { "the image did not answer both chunks" }
    println(elapsed)
    holds.forEach { it.release() }
    environment.end()
}
