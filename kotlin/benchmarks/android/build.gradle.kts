import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    alias(libs.plugins.android.application)
}

/** The repository's root, which holds `spec/` and `compiler/`. */
val repository: File = rootDir.parentFile

/**
 * The compiler: the path the `BATON_COMPILER` Gradle property or environment
 * variable names, else the checkout's release build, else its debug build,
 * as the runtime's build finds it.
 */
fun batonCompiler(): File {
    val named = providers.gradleProperty("BATON_COMPILER").orNull
        ?: providers.environmentVariable("BATON_COMPILER").orNull
    if (named != null && named !in setOf("local", "release")) {
        val file = File(named)
        if (!file.isFile) throw GradleException("BATON_COMPILER names $named, which is not a file; point it at a built batonc")
        return file
    }
    return listOf("release", "debug")
        .map { repository.resolve("compiler/target/$it/batonc") }
        .firstOrNull { it.isFile }
        ?: throw GradleException("no batonc to generate the benchmark's code with: build it with `cargo build` in compiler/, or set BATON_COMPILER to its path")
}

/** A `batonc generate` run, with the directory it writes as a property the Android Gradle plugin can wire. */
abstract class GenerateKotlin : Exec() {
    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty
}

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
// the runtime's device tests generate it.
val generateBenchmarkKotlin = tasks.register<GenerateKotlin>("generateBenchmarkKotlin") {
    description = "Generates the Kotlin of spec/sources/Fixture.graphql with batonc."
    val source = repository.resolve("spec/sources/Fixture.graphql")
    inputs.file(source)
    inputs.files(
        repository.resolve("spec/tests/baton.json"),
        repository.resolve("spec/tests/schema.graphql"),
        repository.resolve("spec/tests/extensions.graphql"),
    )
    inputs.file(providers.provider { batonCompiler() })
    workingDir = repository
    doFirst {
        commandLine(
            batonCompiler().path, "generate", "--language", "kotlin", "--config", "spec/tests/baton.json",
            "--out", outputDirectory.get().asFile.path, source.relativeTo(repository).path,
        )
    }
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
        sources.kotlin?.addGeneratedSourceDirectory(generateBenchmarkKotlin, GenerateKotlin::outputDirectory)
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
