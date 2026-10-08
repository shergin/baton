plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
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
val generateSpecKotlin by tasks.registering(Exec::class) {
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

kotlin {
    jvm()
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
            api(compose.runtime)
            implementation(libs.sqlite)
        }
        jvmMain.dependencies {
            // The JVM has no SQLite of its own: the image's engine on this
            // target alone is the bundled one, a native library inside the
            // artifact. Android will reach the system's through
            // `AndroidSQLiteDriver`.
            implementation(libs.sqlite.bundled)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
        }
        jvmTest {
            kotlin.srcDir(generatedSpec)
            dependencies {
                // The harness walks a `reads` row over a generated lens by its
                // properties' Kotlin names.
                implementation(kotlin("reflect"))
                // The scripts run through the scripted transport an app's tests use.
                implementation(project(":baton-testing"))
                // The composables are tested in a composition, on the desktop's renderer, its main dispatcher the event thread.
                implementation(compose.desktop.uiTestJUnit4)
                implementation(compose.desktop.currentOs)
                implementation(libs.coroutines.swing)
            }
        }
    }
}

tasks.named("compileTestKotlinJvm") { dependsOn(generateSpecKotlin) }
