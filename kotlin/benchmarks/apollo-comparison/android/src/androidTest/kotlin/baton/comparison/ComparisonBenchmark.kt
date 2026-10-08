package baton.comparison

import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.test.Test
import kotlinx.coroutines.runBlocking
import org.junit.runner.RunWith

/**
 * Baton and Apollo Kotlin side by side on the device the instrumentation
 * runs on, in a process that is not debuggable: each line of the report to
 * logcat under the tag `BatonApollo` and to the instrumentation's status.
 */
@RunWith(AndroidJUnit4::class)
class ComparisonBenchmark {
    @Test
    fun both_clients_take_the_fixture_and_the_medians_are_printed() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val debuggable = instrumentation.targetContext.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
        val chip = if (Build.VERSION.SDK_INT >= 31) " (${Build.SOC_MODEL})" else ""
        val machine = "${Build.MANUFACTURER} ${Build.MODEL}$chip, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), " +
            if (debuggable) "a debuggable process" else "a process that is not debuggable"
        runBlocking {
            Comparison.run(resource(BATON), resource(APOLLO), machine) { line ->
                Log.i(TAG, line)
                instrumentation.sendStatus(0, Bundle().apply { putString("stream", "$line\n") })
            }
        }
    }

    private fun resource(name: String): ByteArray {
        val stream = checkNotNull(javaClass.classLoader?.getResourceAsStream(name)) { "$name is not among the test's resources" }
        return stream.use { it.readBytes() }
    }

    private companion object {
        const val TAG = "BatonApollo"
        const val BATON = "characters-page-1.json"
        const val APOLLO = "fixture-apollo.json"
    }
}
