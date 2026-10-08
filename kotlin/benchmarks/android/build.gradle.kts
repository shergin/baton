import baton.gradle.BatonGenerate
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    alias(libs.plugins.android.application)
    id("com.shergin.baton")
}

/** The repository's root, which holds `spec/`. */
val repository: File = rootDir.parentFile

/** A copy of one file into a directory of its own, for a source set that takes directories. */
abstract class CopyResource : DefaultTask() {
    @get:InputFile
    abstract val file: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun copy() {
        val source = file.get().asFile
        source.copyTo(outputDirectory.get().asFile.resolve(source.name), overwrite = true)
    }
}

// The benchmark's one operation, `spec/sources/Fixture.graphql`, generated as
// the runtime's device tests generate it: from the repository's root, so the
// output is named as theirs is.
val generateBenchmarkKotlin = tasks.register<BatonGenerate>("generateBenchmarkKotlin") {
    description = "Generates the Kotlin of spec/sources/Fixture.graphql with batonc."
    workingDirectory.set(repository)
    configuration.set(repository.resolve("spec/tests/baton.json"))
    hosts.from(repository.resolve("spec/sources/Fixture.graphql"))
}

// The Fixture response, which the benchmark reads as a resource.
val copyFixture = tasks.register<CopyResource>("copyFixture") {
    file.set(repository.resolve("spec/rickandmorty/characters-page-1.json"))
}

// The ingest benchmark as an instrumented test of an application built with
// the release build type: the process under test is not debuggable, so ART
// compiles the runtime as it would an app's. The runtime's device test
// (`:baton:connectedAndroidDeviceTest`) runs the same file in a debuggable
// process, which is how the Android Gradle plugin builds a library's device
// test. The release build is signed with the debug key, as the test APK is,
// and is not minified.
android {
    namespace = "baton.benchmarks"
    compileSdk = 36
    defaultConfig {
        applicationId = "baton.benchmarks"
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
        sources.kotlin?.addGeneratedSourceDirectory(generateBenchmarkKotlin, BatonGenerate::outputDirectory)
        sources.resources?.addGeneratedSourceDirectory(copyFixture, CopyResource::outputDirectory)
    }
}

dependencies {
    implementation(project(":baton"))
    androidTestImplementation(kotlin("test-junit", libs.versions.kotlin.get()))
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.junit)
}

// The benchmark measures the runtime's internals, `Ingest` and `Store`, as
// the runtime's own device test does: the runtime's classes are a friend of
// the test's compilation, and the test opts in to the generated code's
// contract, as the runtime's source sets do.
val runtimeBuild: File = rootDir.resolve("baton/build")
tasks.withType<KotlinCompile>().matching { it.name.endsWith("AndroidTestKotlin") }.configureEach {
    friendPaths.from(libraries.filter { it.startsWith(runtimeBuild) })
    compilerOptions.optIn.add("baton.Generated")
}
