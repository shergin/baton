package baton.comparison

import baton.Anchor
import baton.Answer
import baton.Ingest
import baton.Owner
import baton.Store
import baton.check
import baton.comparison.apollo.FixtureQuery
import baton.comparison.apollo.cache.Cache.cache
import baton.spec.Fixture
import com.apollographql.apollo.ApolloClient
import com.apollographql.apollo.api.CustomScalarAdapters
import com.apollographql.apollo.api.Optional
import com.apollographql.apollo.api.json.JsonReader
import com.apollographql.apollo.api.json.jsonReader
import com.benasher44.uuid.uuid4
import com.apollographql.apollo.api.parseResponse
import com.apollographql.cache.normalized.api.CacheHeaders
import com.apollographql.cache.normalized.api.DefaultRecordMerger
import com.apollographql.cache.normalized.api.withErrors
import com.apollographql.cache.normalized.apolloStore
import com.apollographql.cache.normalized.memory.MemoryCacheFactory
import kotlin.jvm.JvmName
import kotlin.time.TimeSource
import okio.Buffer

/**
 * Baton and Apollo Kotlin side by side on the Fixture operation, the Rick
 * and Morty API's first page of characters: the same query, the same graph,
 * each client reading the response recorded for its own query text, on one
 * thread of the machine it runs on. Each step runs [WARM_UP] times, then
 * [RUNS] times, and prints its median and its best.
 *
 * Apollo is configured as its documentation says: an `ApolloClient` with the
 * normalized cache's generated `cache` extension over a `MemoryCacheFactory`,
 * entities keyed by `id` through `@typePolicy`, its own `JsonReader` and its
 * generated adapter. Its write is timed in the pieces
 * `ApolloStore.writeOperation` is made of, the model written back to a map
 * and normalized into records, then the records merged into the cache, and
 * as `writeOperation` whole.
 */
object Comparison {
    const val WARM_UP = 200
    const val RUNS = 300

    /** Rows read per pass of the field-read step, as the Swift benchmarks read them. */
    private const val PASSES = 20

    /** Fields read per row: seven scalars and the origin's name. */
    private const val FIELDS = 8

    /**
     * Runs every step over [batonResponse], the response to Baton's query
     * text, and [apolloResponse], the same data recorded for Apollo's, and
     * passes each line of the report to [report].
     */
    suspend fun run(batonResponse: ByteArray, apolloResponse: ByteArray, machine: String, report: (String) -> Unit) {
        report("Baton and Apollo Kotlin, normalized cache ${com.apollographql.cache.normalized.VERSION}, on $machine")
        report("Fixture: Baton ${batonResponse.size} bytes, Apollo ${apolloResponse.size} bytes; the medians of $RUNS runs after $WARM_UP, then the best")
        baton(batonResponse, report)
        apollo(apolloResponse, report)
        report("JSON alone, for scale")
        line(report, "Apollo JsonReader, every token read, Baton's response", measure { readEveryToken(Buffer().write(batonResponse).jsonReader()) })
        line(report, "Apollo JsonReader, every token read, Apollo's response", measure { readEveryToken(Buffer().write(apolloResponse).jsonReader()) })
    }

    private fun baton(response: ByteArray, report: (String) -> Unit) {
        val operation = Fixture(page = 1)
        report("Baton")
        // Ingest and commit into an empty store, timed apart within each run,
        // as the runtime's `IngestBenchmark` times them.
        val ingests = LongArray(RUNS)
        val commits = LongArray(RUNS)
        val totals = LongArray(RUNS)
        repeat(WARM_UP + RUNS) { run ->
            val store = Store()
            val resolved = store.resolve(Fixture.plan, operation.variables)
            val start = TimeSource.Monotonic.markNow()
            val changes = Ingest.normalize(response, resolved, Store.ROOT_KEY)
            val ingested = start.elapsedNow()
            store.commit(changes)
            val total = start.elapsedNow()
            check(store.count == 901) { "898 entities and three roots, not ${store.count}" }
            if (run < WARM_UP) return@repeat
            ingests[run - WARM_UP] = ingested.inWholeNanoseconds
            commits[run - WARM_UP] = (total - ingested).inWholeNanoseconds
            totals[run - WARM_UP] = total.inWholeNanoseconds
        }
        line(report, "ingest: response bytes to a change set", ingests)
        line(report, "commit into an empty store", commits)
        line(report, "bytes to data in the store, in one run", totals)

        val store = Store()
        val resolved = store.resolve(Fixture.plan, operation.variables)
        val changes = Ingest.normalize(response, resolved, Store.ROOT_KEY)
        store.commit(changes)
        report("  records: ${store.count - 2} (the store's ${store.count} less the mutation and subscription roots)")
        line(report, "the same payload again, nothing changes", measure { store.commit(changes) })
        check(store.check(resolved) == Answer.MEMORY) { "the fixture is not available in memory" }
        line(report, "availability check of the fixture plan", measure { store.check(resolved) })

        val data = Fixture.data(Anchor(store.root, Owner(operation.variables, store)))
        val rows = checkNotNull(data.characters?.results)
        check(rows.size == 20) { "20 rows, not ${rows.size}" }
        var sink = 0
        val reads = measure { sink += readFields(rows) }
        line(report, "one field, an untracked lens read", reads, perRun = PASSES * rows.size * FIELDS)
        check(sink != 42)
    }

    private suspend fun apollo(response: ByteArray, report: (String) -> Unit) {
        val operation = FixtureQuery(page = Optional.present(1))
        val requestUuid = uuid4()
        fun client(): ApolloClient = ApolloClient.Builder()
            .serverUrl("https://rickandmortyapi.com/graphql")
            .cache(MemoryCacheFactory(maxSizeBytes = 10 * 1024 * 1024))
            .build()
        report("Apollo Kotlin")
        // Parse, normalize and merge into an empty cache, timed apart within
        // each run. A new client per run, its cache created before the clock
        // starts.
        val parses = LongArray(RUNS)
        val normalizations = LongArray(RUNS)
        val merges = LongArray(RUNS)
        val totals = LongArray(RUNS)
        var recordCount = 0
        repeat(WARM_UP + RUNS) { run ->
            val client = client()
            val store = client.apolloStore
            store.accessCache { }
            val start = TimeSource.Monotonic.markNow()
            val parsed = operation.parseResponse(Buffer().write(response).jsonReader(), requestUuid, CustomScalarAdapters.Empty)
            val parsedAt = start.elapsedNow()
            val data = checkNotNull(parsed.data) { "no data: ${parsed.exception}" }
            val records = store.normalize(operation, data.withErrors(operation, parsed.errors))
            val normalizedAt = start.elapsedNow()
            store.accessCache { it.merge(records.values, CacheHeaders.NONE, DefaultRecordMerger) }
            val total = start.elapsedNow()
            recordCount = records.size
            client.close()
            if (run < WARM_UP) return@repeat
            parses[run - WARM_UP] = parsedAt.inWholeNanoseconds
            normalizations[run - WARM_UP] = (normalizedAt - parsedAt).inWholeNanoseconds
            merges[run - WARM_UP] = (total - normalizedAt).inWholeNanoseconds
            totals[run - WARM_UP] = total.inWholeNanoseconds
        }
        line(report, "parse: bytes to Operation.Data (JsonReader, adapter)", parses)
        line(report, "normalize: Data to records (withErrors, normalize)", normalizations)
        line(report, "merge into an empty MemoryCache", merges)
        line(report, "bytes to data in the store, in one run", totals)
        report("  records: $recordCount")

        val data = checkNotNull(operation.parseResponse(Buffer().write(response).jsonReader(), requestUuid).data)
        // The same write through the documented call, normalization and merge
        // together, into an empty cache each run.
        val writes = LongArray(RUNS)
        repeat(WARM_UP + RUNS) { run ->
            val client = client()
            val store = client.apolloStore
            store.accessCache { }
            val start = TimeSource.Monotonic.markNow()
            store.writeOperation(operation, data)
            val elapsed = start.elapsedNow()
            client.close()
            if (run >= WARM_UP) writes[run - WARM_UP] = elapsed.inWholeNanoseconds
        }
        line(report, "ApolloStore.writeOperation into an empty cache", writes)

        val client = client()
        val store = client.apolloStore
        val records = store.normalize(operation, data.withErrors(operation, null)).values
        store.writeOperation(operation, data)
        line(report, "the same records merged again, nothing changes", measure {
            val changed = store.accessCache { it.merge(records, CacheHeaders.NONE, DefaultRecordMerger) }
            check(changed.isEmpty()) { "${changed.size} fields changed" }
        })
        line(report, "the same data written again (writeOperation)", measure { store.writeOperation(operation, data) })

        line(report, "readOperation: the cache to Operation.Data", measure {
            val read = store.readOperation(operation)
            checkNotNull(read.data) { "no data read: ${read.exception}" }
        })
        val read = checkNotNull(store.readOperation(operation).data)
        val rows = checkNotNull(read.characters?.results).filterNotNull()
        check(rows.size == 20) { "20 rows, not ${rows.size}" }
        var sink = 0
        val reads = measure { sink += readFields(rows) }
        line(report, "one field, a property of the read Data", reads, perRun = PASSES * rows.size * FIELDS)
        check(sink != 42)
        client.close()
    }

    // The field reads, each side's in a function of its own, so the
    // compiler optimizes the loop as it would a view's body and not as a
    // part of the coroutine that times it.

    private fun readFields(rows: List<Fixture.Data.Characters.Results>): Int {
        var sink = 0
        repeat(PASSES) {
            for (row in rows) {
                sink += row.name?.length ?: 0
                sink += row.status?.length ?: 0
                sink += row.species?.length ?: 0
                sink += row.type?.length ?: 0
                sink += row.gender?.length ?: 0
                sink += row.image?.length ?: 0
                sink += row.created?.length ?: 0
                sink += row.origin?.name?.length ?: 0
            }
        }
        return sink
    }

    @JvmName("readApolloFields")
    private fun readFields(rows: List<FixtureQuery.Result>): Int {
        var sink = 0
        repeat(PASSES) {
            for (row in rows) {
                sink += row.name?.length ?: 0
                sink += row.status?.length ?: 0
                sink += row.species?.length ?: 0
                sink += row.type?.length ?: 0
                sink += row.gender?.length ?: 0
                sink += row.image?.length ?: 0
                sink += row.created?.length ?: 0
                sink += row.origin?.name?.length ?: 0
            }
        }
        return sink
    }

    /**
     * Reads every token of the document under [reader], each name and value
     * read as the generated adapter reads it, and builds nothing.
     */
    private fun readEveryToken(reader: JsonReader) {
        when (reader.peek()) {
            JsonReader.Token.BEGIN_OBJECT -> {
                reader.beginObject()
                while (reader.hasNext()) {
                    reader.nextName()
                    readEveryToken(reader)
                }
                reader.endObject()
            }
            JsonReader.Token.BEGIN_ARRAY -> {
                reader.beginArray()
                while (reader.hasNext()) readEveryToken(reader)
                reader.endArray()
            }
            JsonReader.Token.NUMBER -> reader.nextNumber()
            JsonReader.Token.LONG -> reader.nextLong()
            JsonReader.Token.BOOLEAN -> reader.nextBoolean()
            JsonReader.Token.NULL -> reader.nextNull()
            else -> reader.nextString()
        }
    }

    /** The nanoseconds of [RUNS] runs of [body] after [WARM_UP] untimed ones. */
    private inline fun measure(body: () -> Unit): LongArray {
        repeat(WARM_UP) { body() }
        val samples = LongArray(RUNS)
        for (run in 0 until RUNS) {
            val start = TimeSource.Monotonic.markNow()
            body()
            samples[run] = start.elapsedNow().inWholeNanoseconds
        }
        return samples
    }

    private fun line(report: (String) -> Unit, label: String, samples: LongArray, perRun: Int = 1) {
        val sorted = samples.sorted()
        val median = sorted[sorted.size / 2].toDouble() / perRun
        val best = sorted[0].toDouble() / perRun
        report("  ${label.padEnd(56)} median ${duration(median).padStart(10)}   best ${duration(best).padStart(10)}")
    }

    /** Nanoseconds in the unit that leaves two decimals meaningful. */
    private fun duration(nanoseconds: Double): String = when {
        nanoseconds >= 1_000_000 -> "${decimals(nanoseconds / 1_000_000)} ms"
        nanoseconds >= 1_000 -> "${decimals(nanoseconds / 1_000)} µs"
        else -> "${decimals(nanoseconds)} ns"
    }

    private fun decimals(value: Double): String {
        val hundredths = kotlin.math.round(value * 100).toLong()
        return "${hundredths / 100}.${(hundredths % 100).toString().padStart(2, '0')}"
    }
}
