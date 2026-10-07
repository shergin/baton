package baton

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.TimeSource

/**
 * The lane's first number: the public API's first page, 899 records,
 * ingested and committed into an empty store on the JVM, timed after a
 * warm-up and printed once. Not a benchmark: no device, no budget, no
 * record in `BENCHMARKS.md` until the bench suite runs it.
 */
class IngestTiming {
    @Test
    fun `the public API's first page is ingested and committed, and the time is printed`() {
        val case = Spec.case("rickandmorty/characters-page-1")
        val plan = checkNotNull(case.plan)
        val response = Spec.bytes(case.responses.single())
        val ingests = ArrayList<Long>()
        val commits = ArrayList<Long>()
        repeat(WARM_UP + RUNS) { run ->
            val store = Store()
            val resolved = store.resolve(plan, case.variables)
            val start = TimeSource.Monotonic.markNow()
            val changes = Ingest.normalize(response, resolved, Store.ROOT_KEY)
            val ingested = start.elapsedNow()
            store.commit(changes)
            val committed = start.elapsedNow() - ingested
            assertEquals(901, store.count)
            if (run >= WARM_UP) {
                ingests.add(ingested.inWholeMicroseconds)
                commits.add(committed.inWholeMicroseconds)
            }
        }
        fun median(values: List<Long>) = values.sorted()[values.size / 2] / 1000.0
        println(
            "Fixture (${response.size} bytes, 899 records) on the JVM ${System.getProperty("java.version")}: " +
                "ingest %.2f ms, commit %.2f ms, the medians of $RUNS runs after $WARM_UP".format(median(ingests), median(commits)),
        )
    }

    private companion object {
        const val WARM_UP = 200
        const val RUNS = 100
    }
}
