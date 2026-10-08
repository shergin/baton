package baton.gradle

import java.io.File
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail
import org.gradle.testkit.runner.BuildResult
import org.gradle.testkit.runner.GradleRunner
import org.gradle.testkit.runner.TaskOutcome
import org.junit.jupiter.api.io.TempDir

/**
 * The plugin applied to a project with one host, run by TestKit against the
 * compiler `scripts/build-compiler.sh` builds.
 */
class BatonGenerateTest {
    @TempDir
    lateinit var temporary: Path

    private val project: File get() = temporary.resolve("project").toFile()

    /** The locally built `batonc`; the tests run from `kotlin/baton-gradle`. */
    private val batonc: File by lazy {
        val binary = File("../../compiler/target/release/batonc").canonicalFile
        if (!binary.isFile) fail("$binary is missing; build it with scripts/build-compiler.sh")
        binary
    }

    private val host: File get() = project.resolve("src/main/kotlin/app/Screen.kt")

    private val generated: File get() = project.resolve("build/generated/baton/generateBaton")

    private fun write(fields: String = "id name", withHosts: Boolean = true) {
        project.mkdirs()
        project.resolve("settings.gradle.kts").writeText("rootProject.name = \"app\"\n")
        val hosts = if (withHosts) "hosts.from(fileTree(\"src/main/kotlin\") { include(\"**/*.kt\") })" else ""
        project.resolve("build.gradle.kts").writeText(
            """
            import baton.gradle.BatonGenerate

            plugins {
                id("com.shergin.baton")
            }

            tasks.named<BatonGenerate>("generateBaton") {
                $hosts
            }
            """.trimIndent() + "\n",
        )
        project.resolve("baton.json").writeText("""{"schema": "schema.graphql", "kotlin": {"package": "app"}}""" + "\n")
        File("../../spec/rickandmorty/schema.graphql").copyTo(project.resolve("schema.graphql"), overwrite = true)
        writeHost(fields)
    }

    private fun writeHost(fields: String) {
        host.parentFile.mkdirs()
        host.writeText(
            "package app\n\n" +
                "import baton.Query\n\n" +
                "@Query(\n" +
                "    \$\$\"\"\"\n" +
                "    query ScreenQuery(\$page: Int) {\n" +
                "      characters(page: \$page) { results { $fields } }\n" +
                "    }\n" +
                "    \"\"\",\n" +
                ")\n" +
                "val screen = Unit\n",
        )
    }

    private fun runner(compiler: String = batonc.path, vararg arguments: String): GradleRunner =
        GradleRunner.create()
            .withProjectDir(project)
            .withPluginClasspath()
            .withEnvironment(System.getenv() + mapOf("BATON_COMPILER" to compiler))
            .withArguments(argumentList(*arguments))

    // A daemon watching the file system can miss an edit made just before its next build and call the task up to date.
    private fun argumentList(vararg extra: String): List<String> = listOf("generateBaton", "--stacktrace", "--no-watch-fs") + extra

    private fun generate(vararg arguments: String): BuildResult = runner(batonc.path, *arguments).build()

    private fun BuildResult.outcome(): TaskOutcome? = task(":generateBaton")?.outcome

    @Test
    fun a_host_with_a_query_writes_its_lens_file_the_shared_file_and_the_report() {
        write()
        val result = generate()
        assertEquals(TaskOutcome.SUCCESS, result.outcome())
        assertTrue(generated.resolve("src_main_kotlin_app_Screen.baton.kt").isFile)
        assertTrue(generated.resolve("Baton.baton.kt").isFile)
        assertTrue(project.resolve("build/baton/generateBaton/report.json").isFile)
    }

    @Test
    fun a_second_run_with_nothing_changed_is_up_to_date() {
        write()
        generate()
        assertEquals(TaskOutcome.UP_TO_DATE, generate().outcome())
    }

    @Test
    fun an_edited_host_runs_the_compiler_again() {
        write()
        generate()
        writeHost("id name status")
        assertEquals(TaskOutcome.SUCCESS, generate().outcome())
        assertContains(generated.resolve("src_main_kotlin_app_Screen.baton.kt").readText(), "status")
    }

    @Test
    fun an_edited_schema_runs_the_compiler_again_because_the_configuration_declares_it() {
        write()
        generate()
        project.resolve("schema.graphql").appendText("\n# Edited.\n")
        assertEquals(TaskOutcome.SUCCESS, generate().outcome())
    }

    @Test
    fun a_document_naming_a_field_the_schema_lacks_fails_with_a_located_diagnostic() {
        write(fields = "id nam")
        val result = runner().buildAndFail()
        assertEquals(TaskOutcome.FAILED, result.outcome())
        assertContains(result.output, "src/main/kotlin/app/Screen.kt:")
        assertContains(result.output, ": error:")
    }

    @Test
    fun baton_compiler_naming_a_missing_file_fails_with_the_plugin_message() {
        write()
        val result = runner(temporary.resolve("missing/batonc").toString()).buildAndFail()
        assertContains(result.output, "neither a batonc binary nor a bundle directory")
    }

    @Test
    fun a_task_with_no_hosts_fails_saying_so() {
        write(withHosts = false)
        val result = runner().buildAndFail()
        assertContains(result.output, "has no hosts")
    }

    @Test
    fun baton_compiler_naming_a_bundle_directory_runs_the_variant_for_the_host() {
        write()
        val bundle = temporary.resolve("batonc.artifactbundle").toFile()
        bundle.mkdirs()
        bundle.resolve("info.json").writeText(
            """
            {
              "schemaVersion": "1.0",
              "artifacts": {
                "batonc": {
                  "version": "0.0.0",
                  "type": "executable",
                  "variants": [
                    { "path": "batonc-macos/bin/batonc", "supportedTriples": ["${Host.triple()}"] }
                  ]
                }
              }
            }
            """.trimIndent(),
        )
        val binary = bundle.resolve("batonc-macos/bin/batonc")
        batonc.copyTo(binary)
        assertTrue(binary.setExecutable(true))
        val result = runner(bundle.path).build()
        assertEquals(TaskOutcome.SUCCESS, result.outcome())
        assertTrue(generated.resolve("src_main_kotlin_app_Screen.baton.kt").isFile)
    }

    @Test
    fun the_configuration_cache_is_stored_then_reused_and_the_task_is_up_to_date() {
        write()
        val first = generate("--configuration-cache")
        assertEquals(TaskOutcome.SUCCESS, first.outcome())
        val second = generate("--configuration-cache")
        assertContains(second.output, "Reusing configuration cache")
        assertEquals(TaskOutcome.UP_TO_DATE, second.outcome())
    }
}
