package baton

import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import baton.spec.Fixture
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.TimeSource
import org.junit.runner.RunWith

/**
 * The ingest budget's bench: the Fixture response, the public API's first
 * page of characters (899 records), ingested through the plan `batonc`
 * generates from `spec/sources/Fixture.graphql` and committed into an empty
 * store, on the device the instrumentation runs on. After a warm-up it
 * takes the medians of ingest and of commit over many runs, in time and in
 * bytes allocated, and prints them with what one store holds after the
 * commit, with the device's model and Android version, to logcat under the
 * tag `BatonIngest` and to the instrumentation's status. A number from an
 * emulator is not the budget; the budget is a number on a named device.
 */
@RunWith(AndroidJUnit4::class)
class IngestBenchmark {
    @Test
    fun the_fixture_is_ingested_and_committed_and_the_medians_are_printed() {
        val response = fixtureResponse()
        val operation = Fixture(page = 1)
        val ingests = LongArray(RUNS)
        val commits = LongArray(RUNS)
        val ingestBytes = LongArray(RUNS)
        val commitBytes = LongArray(RUNS)
        repeat(WARM_UP + RUNS) { run ->
            val store = Store()
            val resolved = store.resolve(Fixture.plan, operation.variables)
            val allocatedBefore = bytesAllocated()
            val ingestStart = TimeSource.Monotonic.markNow()
            val changes = Ingest.normalize(response, resolved, Store.ROOT_KEY)
            val ingested = ingestStart.elapsedNow()
            val allocatedAfterIngest = bytesAllocated()
            val commitStart = TimeSource.Monotonic.markNow()
            store.commit(changes)
            val committed = commitStart.elapsedNow()
            val allocatedAfterCommit = bytesAllocated()
            assertEquals(901, store.count, "898 entities and three roots")
            if (run < WARM_UP) return@repeat
            ingests[run - WARM_UP] = ingested.inWholeNanoseconds
            commits[run - WARM_UP] = committed.inWholeNanoseconds
            ingestBytes[run - WARM_UP] = allocatedAfterIngest - allocatedBefore
            commitBytes[run - WARM_UP] = allocatedAfterCommit - allocatedAfterIngest
        }
        val held = storeHeapKilobytes(response, operation)
        val report = "Fixture (${response.size} bytes, 899 records) on ${Build.MANUFACTURER} ${Build.MODEL}, " +
            "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})${if (isEmulator()) ", an emulator" else ""}: " +
            "ingest ${milliseconds(median(ingests))} ms, commit ${milliseconds(median(commits))} ms, " +
            "the medians of $RUNS runs after $WARM_UP; " +
            "the ingest allocates ${kilobytes(median(ingestBytes))} KB and the commit ${kilobytes(median(commitBytes))} KB, " +
            "the medians of the runtime's bytes-allocated counter; a store holds $held KB after the commit"
        Log.i(TAG, report)
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", "$report\n") })
    }

    private fun fixtureResponse(): ByteArray {
        val stream = checkNotNull(javaClass.classLoader?.getResourceAsStream(FIXTURE)) { "$FIXTURE is not among the test's resources" }
        return stream.use { it.readBytes() }
    }

    /** The bytes the runtime has allocated so far, counted as its allocation buffers are handed out, so a difference is good to a buffer. */
    private fun bytesAllocated(): Long = Debug.getRuntimeStat("art.gc.bytes-allocated").toLong()

    /**
     * What one store holds after the commit, in kilobytes: the heap in use
     * after a collection with the store alive, less the heap in use after a
     * collection before it was made. The ingest and the commit happen in a
     * frame of their own, [committedStore], so the change set does not
     * count: this function runs once and so is interpreted, and an
     * interpreted frame keeps alive whatever its registers still hold. One
     * measurement, good to what else the process leaves behind.
     */
    private fun storeHeapKilobytes(response: ByteArray, operation: Fixture): Long {
        val before = heapInUse()
        val store = committedStore(response, operation)
        val after = heapInUse()
        assertEquals(901, store.count)
        return (after - before) / 1024
    }

    /**
     * A new store with the Fixture response committed into it. The change
     * set is a temporary of this frame alone, unreachable once it returns,
     * which is why this is a call and not code in its caller.
     */
    private fun committedStore(response: ByteArray, operation: Fixture): Store {
        val store = Store()
        store.commit(Ingest.normalize(response, store.resolve(Fixture.plan, operation.variables), Store.ROOT_KEY))
        return store
    }

    private fun heapInUse(): Long {
        val runtime = Runtime.getRuntime()
        repeat(2) {
            System.gc()
            System.runFinalization()
        }
        return runtime.totalMemory() - runtime.freeMemory()
    }

    private fun median(values: LongArray): Long = values.sorted()[values.size / 2]

    /** Nanoseconds as milliseconds with two decimals. */
    private fun milliseconds(nanoseconds: Long): String {
        val hundredths = (nanoseconds + 5_000) / 10_000
        return "${hundredths / 100}.${(hundredths % 100).toString().padStart(2, '0')}"
    }

    private fun kilobytes(bytes: Long): Long = (bytes + 512) / 1024

    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE.contains("ranchu") || Build.PRODUCT.contains("sdk")

    private companion object {
        const val TAG = "BatonIngest"
        const val FIXTURE = "characters-page-1.json"
        const val WARM_UP = 200
        const val RUNS = 300
    }
}
