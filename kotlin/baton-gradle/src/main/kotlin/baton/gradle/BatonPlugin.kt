package baton.gradle

import org.gradle.api.Plugin
import org.gradle.api.Project

/**
 * The Gradle plugin `com.shergin.baton`: `batonc generate` as a task with its
 * inputs and outputs declared, and the compiler it runs, the bundle of the
 * release the plugin is versioned with or what `BATON_COMPILER` names. It
 * holds no logic of its own: which source writes which output, the shared
 * file, staleness and diagnostics are the compiler's.
 */
abstract class BatonPlugin : Plugin<Project> {
    override fun apply(project: Project) {
        val release = Release.load()
        val extension = project.extensions.create("baton", BatonExtension::class.java)
        // What `BATON_COMPILER` names, a `batonc` binary or a bundle directory
        // holding an `info.json`, as `Package.swift` and the Bazel extension
        // take it; nothing named means the release's bundle.
        val named = project.providers.gradleProperty("BATON_COMPILER")
            .orElse(project.providers.environmentVariable("BATON_COMPILER"))
        val projectDirectory = project.projectDir
        extension.compiler.convention(project.layout.file(named.map { Compiler.named(it, projectDirectory) }))
        val service = project.gradle.sharedServices.registerIfAbsent("batonCompiler", CompilerService::class.java) {
            parameters.version.set(release.version)
            parameters.bundleSha256.set(release.bundleSha256)
            parameters.cacheDirectory.set(project.gradle.gradleUserHomeDir.resolve("caches/baton"))
            parameters.offline.set(project.gradle.startParameter.isOffline)
        }
        project.tasks.withType(BatonGenerate::class.java).configureEach {
            compiler.convention(extension.compiler)
            compilerService.set(service)
            usesService(service)
            compilerVersion.convention(release.version)
            compilerChecksum.convention(release.bundleSha256)
            workingDirectory.convention(project.layout.projectDirectory)
            configuration.convention(project.layout.projectDirectory.file("baton.json"))
            outputDirectory.convention(project.layout.buildDirectory.dir("generated/baton/$name"))
            report.convention(project.layout.buildDirectory.file("baton/$name/report.json"))
            // The schema and the extensions the configuration names, declared
            // as inputs from its text, which Gradle reads through a provider
            // and so tracks.
            val text = project.providers.fileContents(configuration).asText
            val directory = configuration.map { it.asFile.parentFile }
            configured.from(text.zip(directory) { json, base -> Configuration.files(json, base) }.orElse(emptyList()))
        }
        project.tasks.register("generateBaton", BatonGenerate::class.java) {
            group = "build"
            description = "Generates the Kotlin of the module's documents with batonc."
        }
    }
}
