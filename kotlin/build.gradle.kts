import baton.gradle.BatonExtension
import org.jetbrains.kotlin.compose.compiler.gradle.ComposeCompilerGradlePluginExtension

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.test) apply false
    alias(libs.plugins.android.multiplatform.library) apply false
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.compose) apply false
    alias(libs.plugins.compose.compiler) apply false
    alias(libs.plugins.apollo) apply false
    id("com.shergin.baton") apply false
}

/**
 * The compiler the checkout's modules generate with: the path the
 * `BATON_COMPILER` Gradle property or environment variable names, else the
 * checkout's release build, else its debug build. The Swift package reads
 * `BATON_COMPILER=local` and `=release` as a choice of its own, which names
 * no file here, so either falls through to the checkout's builds.
 */
fun checkoutCompiler(): File {
    val named = providers.gradleProperty("BATON_COMPILER").orNull
        ?: providers.environmentVariable("BATON_COMPILER").orNull
    if (named != null && named !in setOf("local", "release")) {
        val file = File(named)
        if (!file.isFile) throw GradleException("BATON_COMPILER names $named, which is not a file; point it at a built batonc")
        return file
    }
    return listOf("release", "debug")
        .map { rootDir.parentFile.resolve("compiler/target/$it/batonc") }
        .firstOrNull { it.isFile }
        ?: throw GradleException("no batonc to generate with: build it with `cargo build` in compiler/, or set BATON_COMPILER to its path")
}

// The modules generate with the checkout's compiler, not with the release's
// bundle the plugin would fetch, so a change to the emitter is what they
// compile.
subprojects {
    plugins.withId("com.shergin.baton") {
        configure<BatonExtension> {
            compiler.set(layout.file(provider { checkoutCompiler() }))
        }
    }
}

// The Compose compiler's reports, which say whether a class is stable and a
// composable skippable and restartable, off by default: `-PcomposeReports=true`
// writes them under each module's `build/compose-reports`.
if (providers.gradleProperty("composeReports").orNull == "true") {
    subprojects {
        plugins.withId("org.jetbrains.kotlin.plugin.compose") {
            extensions.configure<ComposeCompilerGradlePluginExtension> {
                reportsDestination.set(layout.buildDirectory.dir("compose-reports"))
                metricsDestination.set(layout.buildDirectory.dir("compose-reports"))
            }
        }
    }
}
