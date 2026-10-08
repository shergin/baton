plugins {
    alias(libs.plugins.android.library)
}

/** The repository's root, which holds `spec/` and the Swift comparison. */
val repository: File = rootDir.parentFile

/** A copy of files into a directory of their own under new names, for a source set that takes directories. */
abstract class CopyAssets : DefaultTask() {
    @get:InputFiles
    abstract val files: ConfigurableFileCollection

    @get:Input
    abstract val names: ListProperty<String>

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun copy() {
        for ((source, name) in files.zip(names.get())) source.copyTo(outputDirectory.get().asFile.resolve(name), overwrite = true)
    }
}

// The first page as each client's own query text answers it: Baton's
// fixture and the same data recorded for Apollo's text, the files the
// store-level comparison reads. The other answers, recorded once from the
// live API, are this module's own assets.
val copyFixtures = tasks.register<CopyAssets>("copyFixtures") {
    files.from(
        repository.resolve("spec/rickandmorty/characters-page-1.json"),
        repository.resolve("benchmarks/apollo-comparison/fixture-apollo.json"),
    )
    names.set(listOf("baton-characters-1.json", "apollo-characters-1.json"))
}

// The fixed server both measured apps run on the loopback interface, and
// the trace sections they emit, so both are measured from the same bytes
// by the same marks.
android {
    namespace = "baton.macro.server"
    compileSdk = 36
    defaultConfig {
        minSdk = 23
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(copyFixtures, CopyAssets::outputDirectory)
    }
}

dependencies {
    api(libs.tracing)
}
