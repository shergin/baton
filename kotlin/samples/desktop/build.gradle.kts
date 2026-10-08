plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
}

/** The repository's root, which holds `spec/` and `compiler/`. */
val repository: File = rootDir.parentFile

/** Where the compiler writes the code it generates for the sample's hosts. */
val generated: Provider<Directory> = layout.buildDirectory.dir("generated/baton")

/** The hosts: every Kotlin file of the sample, which the compiler scans for `@Query` and `@Fragment`. */
val hosts: ConfigurableFileTree = fileTree("src/jvmMain/kotlin") { include("**/*.kt") }

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
        ?: throw GradleException("no batonc to generate the sample's code with: build it with `cargo build` in compiler/, or set BATON_COMPILER to its path")
}

// What an app's build does: the compiler reads the hosts' documents and
// writes their lenses and operations beside the sources it compiles.
val generateBaton = tasks.register<Exec>("generateBaton") {
    description = "Generates the Kotlin of the sample's documents with batonc."
    inputs.files(hosts)
    inputs.file("baton.json")
    inputs.file(repository.resolve("spec/rickandmorty/schema.graphql"))
    inputs.file(providers.provider { batonCompiler() })
    outputs.dir(generated)
    workingDir = projectDir
    doFirst {
        val sources = hosts.files.map { it.relativeTo(projectDir).path }.sorted()
        commandLine(listOf(batonCompiler().path, "generate", "--language", "kotlin", "--config", "baton.json", "--out", generated.get().asFile.path) + sources)
    }
}

kotlin {
    jvm()
    sourceSets {
        jvmMain {
            kotlin.srcDir(generated)
            dependencies {
                implementation(project(":baton"))
                // The store inspector, the window's third pane.
                implementation(project(":baton-inspector"))
                implementation(compose.desktop.currentOs)
                implementation(libs.compose.foundation)
                implementation(libs.compose.material3)
                // The environment commits on the main dispatcher, the desktop's event thread.
                implementation(libs.coroutines.swing)
            }
        }
    }
}

tasks.named("compileKotlinJvm") { dependsOn(generateBaton) }

compose.desktop {
    application {
        mainClass = "baton.sample.MainKt"
    }
}

// The screens drawn to PNG files without a window, for the README and for a
// machine with no screen; see `Screenshot.kt`.
tasks.register<JavaExec>("screenshot") {
    description = "Renders the sample's screens to build/screenshots over the live API."
    group = "application"
    val main = kotlin.jvm().compilations.getByName("main")
    dependsOn(main.compileTaskProvider)
    mainClass.set("baton.sample.ScreenshotKt")
    classpath = main.output.allOutputs + main.runtimeDependencyFiles!!
    args(layout.buildDirectory.dir("screenshots").get().asFile.path)
}
