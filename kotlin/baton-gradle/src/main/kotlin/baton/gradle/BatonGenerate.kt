package baton.gradle

import java.io.File
import javax.inject.Inject
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.ConfigurableFileCollection
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.InputFiles
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.gradle.process.ExecOperations

/**
 * One `batonc generate` run: the hosts, the configuration and what it names
 * in, the generated Kotlin and the report out. The plugin registers one,
 * `generateBaton`, with the project's `baton.json`; a module with sources
 * against two schemas registers a second.
 */
@CacheableTask
abstract class BatonGenerate : DefaultTask() {
    /** The host sources the compiler scans for `@Fragment`, `@Query`, `@Mutation` and `@Subscription`: `.kt`, `.graphql` and `.gql` files. */
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val hosts: ConfigurableFileCollection

    /** `baton.json`; by convention the project's own. */
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val configuration: RegularFileProperty

    /** What the configuration names beside itself, the schema and its extensions, which the plugin declares from its text. */
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val configured: ConfigurableFileCollection

    /** A schema in place of the configuration's, passed as `--schema`, for one that is a build's own output. */
    @get:InputFile
    @get:Optional
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val schema: RegularFileProperty

    /**
     * The directory the compiler runs in. A host under it is passed by its
     * relative path, which names its output and its diagnostics; by
     * convention the project directory.
     */
    @get:Internal
    abstract val workingDirectory: DirectoryProperty

    /** Where the generated Kotlin goes, one file per host and the shared file: a source directory of the module's. */
    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    /** The report, what the run compiled, as `--report` writes it. */
    @get:OutputFile
    abstract val report: RegularFileProperty

    /** The persisted documents file under `persistConfig`, where `--persisted` puts it; unset, the compiler writes it under the output directory. */
    @get:OutputFile
    @get:Optional
    abstract val persisted: RegularFileProperty

    /** The `batonc` binary, when one is named; else the service fetches the release's. A rebuilt compiler regenerates. */
    @get:InputFile
    @get:Optional
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val compiler: RegularFileProperty

    /** The release whose bundle the service fetches, an input so a new release regenerates. */
    @get:Input
    abstract val compilerVersion: Property<String>

    /** That bundle's checksum. */
    @get:Input
    abstract val compilerChecksum: Property<String>

    @get:Internal
    abstract val compilerService: Property<CompilerService>

    @get:Inject
    protected abstract val execOperations: ExecOperations

    @TaskAction
    fun generate() {
        val binary = compiler.orNull?.asFile ?: compilerService.get().compiler()
        val directory = workingDirectory.get().asFile
        val sources = hosts.files.map { path(it, directory) }.sorted()
        if (sources.isEmpty()) {
            throw GradleException("$name has no hosts: add the module's sources, `hosts.from(fileTree(\"src/commonMain/kotlin\"))`")
        }
        val out = outputDirectory.get().asFile
        out.mkdirs()
        val reportFile = report.get().asFile
        reportFile.parentFile.mkdirs()
        val command = mutableListOf(
            binary.path, "generate", "--language", "kotlin",
            "--config", path(configuration.get().asFile, directory),
            "--out", out.path,
            "--report", reportFile.path,
        )
        schema.orNull?.let { command += listOf("--schema", it.asFile.path) }
        persisted.orNull?.let { command += listOf("--persisted", it.asFile.path) }
        command += sources
        // The compiler's diagnostics go to stderr as `path:line:column: error:
        // message`, which Gradle shows at the line; a failed run has written
        // nothing.
        execOperations.exec {
            workingDir = directory
            commandLine(command)
        }
    }

    /** A file's path as the compiler is given it: relative to the working directory when under it, else as it is. */
    private fun path(file: File, directory: File): String {
        val relative = file.relativeToOrNull(directory) ?: return file.path
        return if (relative.path.startsWith("..")) file.path else relative.path
    }
}
