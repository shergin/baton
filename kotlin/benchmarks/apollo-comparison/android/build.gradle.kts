plugins {
    alias(libs.plugins.android.application)
}

/** The repository's root, which holds `spec/` and the Swift comparison. */
val repository: File = rootDir.parentFile

/** A copy of files into a directory of their own, for a source set that takes directories. */
abstract class CopyResources : DefaultTask() {
    @get:InputFiles
    abstract val files: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun copy() {
        for (source in files) source.copyTo(outputDirectory.get().asFile.resolve(source.name), overwrite = true)
    }
}

// Both responses, which the bench reads as resources: Baton's, and the same
// data recorded for Apollo's query text.
val copyFixtures = tasks.register<CopyResources>("copyFixtures") {
    files.from(
        repository.resolve("spec/rickandmorty/characters-page-1.json"),
        repository.resolve("benchmarks/apollo-comparison/fixture-apollo.json"),
    )
}

// The side-by-side bench on a device, as an instrumented test of an
// application built with the release build type, so the process under test
// is not debuggable and ART compiles both clients as it would an app's: the
// shape of `benchmarks/android`. The release build is signed with the debug
// key, as the test APK is, and is not minified.
android {
    namespace = "baton.comparison.android"
    compileSdk = 36
    defaultConfig {
        applicationId = "baton.comparison.android"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    testBuildType = "release"
}

androidComponents {
    onVariants { variant ->
        val sources = variant.androidTest?.sources ?: return@onVariants
        sources.resources?.addGeneratedSourceDirectory(copyFixtures, CopyResources::outputDirectory)
    }
}

dependencies {
    implementation(project(":benchmarks:apollo-comparison"))
    androidTestImplementation(kotlin("test-junit", libs.versions.kotlin.get()))
    androidTestImplementation(libs.coroutines.core)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
}
