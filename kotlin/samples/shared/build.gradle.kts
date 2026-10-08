import baton.gradle.BatonGenerate
import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.android.multiplatform.library)
    id("com.shergin.baton")
}

// What an app's build does: the compiler reads the hosts' documents and
// writes their lenses and operations beside the sources it compiles.
val generateBaton = tasks.named<BatonGenerate>("generateBaton") {
    hosts.from(fileTree("src/commonMain/kotlin") { include("**/*.kt") })
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
            // The task's output as the directory, so every task that reads
            // the sources, the compilations and the sources jar, runs it first.
            kotlin.srcDir(generateBaton.flatMap { it.outputDirectory })
            dependencies {
                api(project(":baton"))
                api(project(":baton-inspector"))
                api(libs.compose.foundation)
                api(libs.compose.material3)
            }
        }
    }
}
