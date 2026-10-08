import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.android.multiplatform.library)
}

/** The repository's root, which holds `spec/` and `compiler/`. */
val repository: File = rootDir.parentFile

/** Where the compiler writes the code it generates for the sample's hosts. */
val generated: Provider<Directory> = layout.buildDirectory.dir("generated/baton")

/** The hosts: every Kotlin file of the screens, which the compiler scans for `@Query` and `@Fragment`. */
val hosts: ConfigurableFileTree = fileTree("src/commonMain/kotlin") { include("**/*.kt") }

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

// The sample's screens, which the desktop app and the Android app both show:
// Compose Multiplatform in common code, over the runtime and the inspector.
// An avatar is fetched over `java.net`, which the JVM and Android share, and
// decoded by each platform's own decoder.
kotlin {
    jvm()
    android {
        namespace = "baton.sample"
        // Compose UI 1.12 is compiled against Android 17's API and asks the
        // same of what depends on it.
        compileSdk = 37
        minSdk = 23
    }
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    applyDefaultHierarchyTemplate {
        common {
            group("jvmShared") {
                withJvm()
                withCompilations { it.platformType == KotlinPlatformType.androidJvm }
            }
        }
    }
    sourceSets {
        commonMain {
            // The task as the directory, so every task that reads the sources,
            // the compilations and the sources jar, runs it first.
            kotlin.srcDir(generateBaton)
            dependencies {
                api(project(":baton"))
                api(project(":baton-inspector"))
                api(libs.compose.foundation)
                api(libs.compose.material3)
            }
        }
    }
}
