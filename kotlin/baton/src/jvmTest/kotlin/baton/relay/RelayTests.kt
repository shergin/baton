package baton.relay

import baton.Anchor
import baton.Ingest
import baton.Json
import baton.OperationKind
import baton.OperationType
import baton.Owner
import baton.Script
import baton.Spec
import baton.Store
import baton.Variables
import baton.check
import baton.dump
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The cases harvested from Relay's own store tests into `spec/relay/`, run
 * as `swift/Tests/BatonRelayTests/RelayTests.swift` runs them: each case
 * commits the payload Relay's test normalized and compares the store with
 * the records Relay's test expected, and each script commits its payloads
 * in a row, checks availability and reads through the generated lenses
 * what Relay's reader read. Relay's tests are measured against, not obeyed:
 * a case or script with a status runs as a known issue, which fails once it
 * passes, except an unsupported feature's, which is left out of the runs.
 * `spec/relay/README.md` says what each status means.
 */
class RelayTests {
    /**
     * The cases and scripts, by name, where the Kotlin runtime legitimately
     * parts from the Swift runtime, with the reason: a listed one with a
     * status must pass, and a listed one without a status must fail.
     */
    private val differences: Map<String, String> = emptyMap()

    /** What a case or a script is held to: its name, and the status the harvest gives it. */
    private class Marks(val name: String, val status: String?, val note: String?) {
        val isRun: Boolean get() = status != "unsupported-feature"
    }

    /** The results of a run of cases or scripts: the failures of the test, and the names that met what they are held to. */
    private class Tally {
        val failures = ArrayList<String>()
        val met = ArrayList<String>()
        var runs = 0
    }

    private val cases: List<Spec.Case> by lazy { Spec.manifest("relay/manifest.json", PACKAGE) }

    private val scripts: List<String> by lazy { Script.paths("relay/manifest.json") }

    @Test
    fun `a payload Relay's tests commit leaves the records Relay's test expects`() {
        val tally = Tally()
        for (case in cases) {
            val marks = Marks(case.name, case.status, case.note)
            if (!marks.isRun) continue
            measured(marks, tally) { issues ->
                val store = Store()
                store.log = null
                for (response in case.responses) commit(case.operation, case.variables, response, store)
                Spec.difference(store.dump(), Spec.text(case.records), case.records)?.let { issues.add(it) }
            }
        }
        report("cases", tally)
    }

    @Test
    fun `payloads Relay's tests commit in a row leave the records Relay's test expects, a check after them gives Relay's answer, and a lens reads what Relay's reader reads`() {
        val tally = Tally()
        for (path in scripts) {
            val script = Script.load(path)
            val marks = Marks(path, script.status, script.note)
            if (!marks.isRun) continue
            measured(marks, tally) { issues ->
                val store = Store()
                store.log = null
                for ((index, step) in script.steps.withIndex()) {
                    val context = "after step ${index + 1}: "
                    when (val action = step.action) {
                        is Script.Action.Payload -> commit(action.operation.name, variables(action.operation.variables), action.response, store)
                        is Script.Action.Check -> {
                            val type = operation(action.operation.name)
                            val answer = store.check(store.resolve(type.plan, variables(action.operation.variables))).name.lowercase()
                            val expected = step.answer
                            if (expected != null && answer != expected) {
                                issues.add("step ${index + 1}: the check answers $answer where Relay's answer is $expected")
                            }
                        }
                        else -> {
                            issues.add("step ${index + 1} is a `${action.kind}`, which the Relay scripts do not take")
                            return@measured
                        }
                    }
                    step.records?.let { records ->
                        Spec.difference(store.dump(), Spec.text(records), records)?.let { issues.add(context + it) }
                    }
                    if (step.reads.isNotEmpty()) expectReads(step.reads, store, context, issues)
                }
            }
        }
        report("scripts", tally)
    }

    @Test
    fun `every operation the Relay cases and scripts compile has its document in the spec, equal to the text the compiler generated`() {
        val names = cases.map { it.operation }.toMutableSet()
        for (path in scripts) {
            for (step in Script.load(path).steps) {
                when (val action = step.action) {
                    is Script.Action.Payload -> names.add(action.operation.name)
                    is Script.Action.Check -> names.add(action.operation.name)
                    else -> {}
                }
            }
        }
        val failures = ArrayList<String>()
        var compared = 0
        for (name in names.sorted()) {
            val type = Spec.operation(name, PACKAGE) ?: continue
            compared += 1
            val document = "relay/documents/$name.graphql"
            val file = File(Spec.directory, document)
            if (!file.isFile) {
                failures.add("$document is missing")
                continue
            }
            if (file.readText() != (type.text ?: "") + "\n") failures.add("$document differs from the text the compiler generated")
        }
        assertTrue(compared > 0, "the Relay cases and scripts name generated operations")
        if (failures.isNotEmpty()) fail("${failures.size} of $compared documents differ:\n" + failures.joinToString("\n"))
    }

    // Helpers.

    /**
     * Compares what the generated lens reads at each row with the row: its
     * value, its `@catch` result, or what it throws. The row at the empty
     * path is the operation's own outcome, and without one the operation
     * reads.
     */
    private fun expectReads(rows: List<Script.Read>, store: Store, context: String, issues: MutableList<String>) {
        val first = rows.first()
        val name = first.operation ?: run {
            issues.add("${context}a read names no operation")
            return
        }
        val type = operation(name)
        val anchor = Anchor(store.root(OperationKind.QUERY), Owner(variables(first.variables), store))
        val outcome = outcome(type, anchor)
        val expected = rows.firstOrNull { it.path.isEmpty() }?.throws
        if (outcome != expected) {
            issues.add("${context}the operation ${outcome?.let { "fails with $it" } ?: "reads"} where Relay's ${expected?.let { "fails with $it" } ?: "reads"}")
        }
        val data = type.data(anchor)
        for (row in rows) {
            if (row.path.isEmpty()) continue
            val actual = try {
                relayRead(data, row.path)
            } catch (error: Exception) {
                RelayRead.Threw(error.toString())
            }
            if (actual == null) {
                issues.add("${context}the lens reads no ${row.path}")
                continue
            }
            val wanted = row.throws?.let { RelayRead.Threw(it) } ?: RelayRead.Value(row.result ?: row.value)
            if (!actual.isSame(wanted)) issues.add("${context}the lens reads ${row.path} as $actual where Relay reads $wanted")
        }
    }

    /** What an operation's own read fails with: a `@required` field that bubbled to its root, or field errors under `@throwOnFieldError`. */
    private fun outcome(type: OperationType<*>, anchor: Anchor): String? {
        if (type.missingRequiredField(anchor) != null) return "requiredField"
        if (type.throwsOnFieldError && type.fieldErrors(anchor).isNotEmpty()) return "fieldErrors"
        return null
    }

    /**
     * Runs a case's body, which adds what differs to the list it is given,
     * and holds the result to the case's marks: without a status the body
     * must find nothing, with one it must find something, and a case the
     * table of differences lists is held to the opposite.
     */
    private fun measured(marks: Marks, tally: Tally, body: (MutableList<String>) -> Unit) {
        tally.runs += 1
        val issues = ArrayList<String>()
        try {
            body(issues)
        } catch (error: Exception) {
            issues.add("threw $error")
        }
        val difference = differences[marks.name]
        val mustPass = (marks.status == null) != (difference != null)
        when {
            mustPass && issues.isNotEmpty() -> {
                val held = if (marks.status == null) "" else " (${marks.status}, listed as a difference: $difference)"
                tally.failures.add("${marks.name}$held:\n  " + issues.joinToString("\n  "))
            }
            !mustPass && issues.isEmpty() -> {
                val held = marks.status?.let { "$it: ${marks.note ?: ""}" } ?: "listed as a difference: $difference"
                tally.failures.add("${marks.name} passes now: revisit its status ($held)")
            }
            else -> tally.met.add(marks.name)
        }
    }

    private fun report(what: String, tally: Tally) {
        assertTrue(tally.runs > 0, "the Relay manifest has $what to run")
        println("Relay $what that met what they are held to: ${tally.met.size} of ${tally.runs}")
        if (tally.failures.isNotEmpty()) fail("${tally.failures.size} of ${tally.runs} $what fail:\n" + tally.failures.joinToString("\n"))
    }

    /** The generated operation [name] in `baton.relay`. */
    private fun operation(name: String): OperationType<*> =
        Spec.operation(name, PACKAGE) ?: error("no generated operation is named $name")

    private fun variables(json: Map<String, Any?>): Variables = Variables(json.mapValues { Json.variable(it.value) })

    /** Commits a response as a payload: the ingest takes what the response holds, and a field it does not hold stays as the store had it. */
    private fun commit(name: String, variables: Variables, response: String, store: Store) {
        val type = operation(name)
        store.commit(Ingest.normalize(Spec.bytes(response), store.resolve(type.plan, variables), Store.rootKey(type.kind)))
    }

    private companion object {
        /** The package `spec/relay/baton.json` generates into. */
        const val PACKAGE = "baton.relay"
    }
}
