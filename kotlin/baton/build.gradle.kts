import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.android.multiplatform.library)
}

/** The repository's root, which holds `spec/` and `compiler/`. */
val repository: File = rootDir.parentFile

/** Where the compiler writes the code it generates for the specification's sources. */
val generatedSpec: Provider<Directory> = layout.buildDirectory.dir("generated/baton/spec")

/**
 * The compiler that generates the specification's code: the path the
 * `BATON_COMPILER` Gradle property or environment variable names, else the
 * checkout's release build, else its debug build. The Swift package reads
 * `BATON_COMPILER=local` and `=release` as a choice of its own, which names
 * no file here, so either falls through to the checkout's builds.
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
        ?: throw GradleException(
            "no batonc to generate the specification's code with: build it with `cargo build` in compiler/, " +
                "or set BATON_COMPILER to its path",
        )
}

// The specification's sources, generated as the Kotlin target writes them,
// are the test source set's lenses and plans: the harness runs the
// manifest's cases through the code an app would compile.
val generateSpecKotlin = tasks.register<Exec>("generateSpecKotlin") {
    description = "Generates the Kotlin of spec/sources with batonc."
    val sources = repository.resolve("spec/sources")
    inputs.dir(sources)
    inputs.files(
        repository.resolve("spec/tests/baton.json"),
        repository.resolve("spec/tests/schema.graphql"),
        repository.resolve("spec/tests/extensions.graphql"),
    )
    // The compiler is an input too, found when the task runs, so a rebuilt
    // compiler generates again.
    inputs.file(providers.provider { batonCompiler() })
    outputs.dir(generatedSpec)
    workingDir = repository
    doFirst {
        val files = sources.listFiles { file -> file.extension == "graphql" }.orEmpty().map { it.relativeTo(repository).path }.sorted()
        commandLine(
            listOf(batonCompiler().path, "generate", "--language", "kotlin", "--config", "spec/tests/baton.json", "--out", generatedSpec.get().asFile.path) + files,
        )
    }
}

/** Where the compiler writes the benchmark's plan, the Fixture query's alone. */
val generatedBenchmark: Provider<Directory> = layout.buildDirectory.dir("generated/baton/benchmark")

// The device tests' one operation, `spec/sources/Fixture.graphql`, generated
// as the specification's sources are: the ingest benchmark and the image's
// tests on Android run through the plan an app would compile, and need none
// of the converters the other sources name.
val generateBenchmarkKotlin = tasks.register<Exec>("generateBenchmarkKotlin") {
    description = "Generates the Kotlin of spec/sources/Fixture.graphql with batonc."
    val source = repository.resolve("spec/sources/Fixture.graphql")
    inputs.file(source)
    inputs.files(
        repository.resolve("spec/tests/baton.json"),
        repository.resolve("spec/tests/schema.graphql"),
        repository.resolve("spec/tests/extensions.graphql"),
    )
    inputs.file(providers.provider { batonCompiler() })
    outputs.dir(generatedBenchmark)
    workingDir = repository
    doFirst {
        commandLine(
            batonCompiler().path, "generate", "--language", "kotlin", "--config", "spec/tests/baton.json",
            "--out", generatedBenchmark.get().asFile.path, source.relativeTo(repository).path,
        )
    }
}

kotlin {
    jvm()
    android {
        namespace = "baton"
        compileSdk = 36
        // The lowest the dependencies allow: the Compose runtime and the
        // AndroidX SQLite driver both start at Android 6.
        minSdk = 23
        // The common tests run on the host too, against Android's API.
        withHostTest {}
        // The ingest benchmark and the image's tests on the system's SQLite
        // run on a device or an emulator: `connectedAndroidDeviceTest`.
        withDeviceTest {
            instrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        }
    }
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    applyDefaultHierarchyTemplate {
        common {
            // What the JVM and Android both run: `java.net`, `java.io` and
            // `java.util.concurrent`, which the two platforms share.
            group("jvmShared") {
                withJvm()
                withCompilations { it.platformType == KotlinPlatformType.androidJvm }
            }
        }
    }
    sourceSets {
        // The runtime is the one module that uses its own contract with
        // generated code everywhere; generated files opt in per file.
        all { languageSettings.optIn("baton.Generated") }
        commonMain.dependencies {
            // The runtime depends on the standard library, kotlinx-coroutines,
            // the Compose runtime and the AndroidX SQLite driver API, and
            // nothing else; the image's engine and the transports are each
            // target's actuals. Generated code names Compose's `Stable`, so
            // the Compose runtime is part of the runtime's API. The driver API
            // is interfaces alone: the image is written against it, and each
            // target supplies a driver.
            implementation(libs.coroutines.core)
            api(libs.compose.runtime)
            implementation(libs.sqlite)
        }
        jvmMain.dependencies {
            // The JVM has no SQLite of its own: the image's engine on this
            // target alone is the bundled one, a native library inside the
            // artifact.
            implementation(libs.sqlite.bundled)
        }
        androidMain.dependencies {
            // The system's SQLite, through the framework's `SQLiteDatabase`.
            implementation(libs.sqlite.framework)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
        }
        getByName("androidDeviceTest") {
            kotlin.srcDir(generatedBenchmark)
            // The ingest benchmark, which `benchmarks/android` runs in a
            // process that is not debuggable; here it runs in the device
            // test's, which is.
            kotlin.srcDir(rootDir.resolve("benchmarks/android/src/androidTest/kotlin"))
            // The Fixture response, read as a resource.
            resources.srcDir(repository.resolve("spec/rickandmorty"))
            resources.include("characters-page-1.json")
            dependencies {
                implementation(kotlin("test"))
                implementation(libs.coroutines.test)
                implementation(libs.androidx.test.runner)
                implementation(libs.androidx.test.junit)
            }
        }
        jvmTest {
            kotlin.srcDir(generatedSpec)
            dependencies {
                // The harness walks a `reads` row over a generated lens by its
                // properties' Kotlin names.
                implementation(kotlin("reflect"))
                // The scripts run through the scripted transport an app's tests use.
                implementation(project(":baton-testing"))
                // The inspector is held in a composition over the specification's operations.
                implementation(project(":baton-inspector"))
                // The composables are tested in a composition, on the desktop's renderer, its main dispatcher the event thread.
                implementation(libs.compose.ui.test.junit4)
                implementation(compose.desktop.currentOs)
                implementation(libs.coroutines.swing)
            }
        }
    }
}

tasks.named("compileTestKotlinJvm") { dependsOn(generateSpecKotlin) }
tasks.named("compileAndroidDeviceTest") { dependsOn(generateBenchmarkKotlin) }

// The runtime has no Compose resources. The Compose plugin, applied for the
// desktop renderer the JVM tests compose on, would copy the device tests'
// none into assets through a task the Android library plugin leaves
// unconfigured.
tasks.matching { it.name == "copyAndroidDeviceTestComposeResourcesToAndroidAssets" }.configureEach { enabled = false }
