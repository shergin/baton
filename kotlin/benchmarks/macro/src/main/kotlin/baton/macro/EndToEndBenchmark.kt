package baton.macro

import android.content.ComponentName
import android.content.Intent
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.ExperimentalMetricApi
import androidx.benchmark.macro.FrameTimingGfxInfoMetric
import androidx.benchmark.macro.FrameTimingMetric
import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.TraceSectionMetric
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * Baton's Android sample and its Apollo Kotlin twin, end to end on the
 * device, measured the same way: release builds that are not debuggable,
 * compiled ahead of time in full, launched with `FixedServer.EXTRA` so each
 * fetches from the fixed server in its own process, [ITERATIONS] runs of
 * every scenario. The trace sections are the apps' own, under the names
 * `Sections` gives them in both.
 */
@OptIn(ExperimentalMetricApi::class)
@RunWith(Parameterized::class)
class EndToEndBenchmark(private val app: String) {
    @get:Rule
    val rule = MacrobenchmarkRule()

    /** A cold start with no store on disk: the list waits for the server's response. */
    @Test
    fun cold_start_to_the_list_with_an_empty_store() = rule.measureRepeated(
        packageName = app,
        metrics = startMetrics,
        compilationMode = CompilationMode.Full(),
        startupMode = StartupMode.COLD,
        iterations = ITERATIONS,
        setupBlock = { clearData() },
    ) {
        launch()
    }

    /**
     * A cold start over the store an earlier launch left on disk: neither app
     * asks the network for data its store holds, so the list is drawn from
     * the store; the time to it is `timeToFullDisplayMs`.
     */
    @Test
    fun cold_start_to_the_list_with_a_warm_store() {
        var primed = false
        rule.measureRepeated(
            packageName = app,
            metrics = startMetrics,
            compilationMode = CompilationMode.Full(),
            startupMode = StartupMode.COLD,
            iterations = ITERATIONS,
            setupBlock = {
                if (!primed) {
                    prime()
                    primed = true
                }
            },
        ) {
            launch()
        }
    }

    /** From the tap on a row to the first draw of its detail, the header from the store, in a process that has just shown the list. */
    @Test
    fun tap_a_row_to_the_detail() = rule.measureRepeated(
        packageName = app,
        metrics = listOf(TraceSectionMetric(Sections.DETAIL_TAP_TO_FRAME, TraceSectionMetric.Mode.First)),
        compilationMode = CompilationMode.Full(),
        startupMode = null,
        iterations = ITERATIONS,
        setupBlock = {
            killProcess()
            clearData()
            launch()
        },
    ) {
        device.findObject(By.text(ROW)).click()
        check(device.wait(Until.hasObject(By.text(HEADER)), TIMEOUT)) { "$app showed no detail" }
    }

    /** From the tap on Next to the first draw of the second page, its response from the fixed server. */
    @Test
    fun a_page_turn() = rule.measureRepeated(
        packageName = app,
        metrics = listOf(TraceSectionMetric(Sections.PAGE_TURN_TO_FRAME, TraceSectionMetric.Mode.First)),
        compilationMode = CompilationMode.Full(),
        startupMode = null,
        iterations = ITERATIONS,
        setupBlock = {
            killProcess()
            clearData()
            launch()
        },
    ) {
        device.findObject(By.text("Next")).click()
        check(device.wait(Until.hasObject(By.text(SECOND_PAGE)), TIMEOUT)) { "$app showed no second page" }
    }

    /** The first page scrolled down and back twice, from the warm store, its avatars from the fixed server. */
    @Test
    fun scrolling_the_list() {
        var primed = false
        rule.measureRepeated(
            packageName = app,
            metrics = listOf(FrameTimingMetric(), FrameTimingGfxInfoMetric()),
            compilationMode = CompilationMode.Full(),
            startupMode = null,
            iterations = ITERATIONS,
            setupBlock = {
                if (!primed) {
                    prime()
                    primed = true
                }
                killProcess()
                launch()
                // The visible avatars arrive from the fixed server.
                Thread.sleep(1_000)
            },
        ) {
            val list = checkNotNull(device.findObject(By.scrollable(true))) { "$app shows no scrollable list" }
            list.setGestureMargin(device.displayWidth / 5)
            repeat(2) {
                list.fling(Direction.DOWN)
                device.waitForIdle()
                list.fling(Direction.UP)
                device.waitForIdle()
            }
        }
    }

    private fun MacrobenchmarkScope.launch() {
        val intent = Intent().setComponent(ComponentName(app, "$app.MainActivity")).putExtra(FixedServer.EXTRA, true)
        startActivityAndWait(intent)
        check(device.wait(Until.hasObject(By.text(FIRST_ROW)), TIMEOUT)) { "$app showed no list" }
    }

    private fun MacrobenchmarkScope.clearData() {
        device.executeShellCommand("pm clear $app")
    }

    /** One launch from an empty store whose response the store keeps on disk, then the process ended. */
    private fun MacrobenchmarkScope.prime() {
        killProcess()
        clearData()
        launch()
        // Baton's image is written behind on a thread of its own; Apollo's
        // SQL cache before the response is emitted. Both are done by now.
        Thread.sleep(2_000)
        killProcess()
    }

    /** A start's metrics: the startup's, the list's two sections from the response, and the client's construction. */
    private val startMetrics = listOf(
        StartupTimingMetric(),
        TraceSectionMetric(Sections.LIST_RESPONSE_TO_FRAME, TraceSectionMetric.Mode.First),
        TraceSectionMetric(Sections.LIST_LAST_BYTE_TO_FRAME, TraceSectionMetric.Mode.First),
        TraceSectionMetric(Sections.CLIENT_SETUP, TraceSectionMetric.Mode.First),
    )

    companion object {
        const val ITERATIONS = 15
        private const val TIMEOUT = 10_000L
        private const val FIRST_ROW = "Rick Sanchez"
        private const val ROW = "Agency Director"
        private const val HEADER = "Last seen"
        private const val SECOND_PAGE = "Aqua Morty"

        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun apps(): List<String> = listOf("baton.sample.android", "baton.sample.apollo")
    }
}
