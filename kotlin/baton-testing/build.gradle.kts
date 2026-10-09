import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.multiplatform.library)
    alias(libs.plugins.maven.publish)
}

// The transports an app's tests run the runtime over: scripted, recorded and
// silent. They are transports like any other, and nothing behind them can
// tell. On the JVM and on Android alike, so an app's instrumented tests have
// them too; the socket server double is the two platforms' shared Java.
kotlin {
    jvm()
    android {
        namespace = "baton.testing"
        compileSdk = 36
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
        commonMain.dependencies {
            api(project(":baton"))
            implementation(libs.coroutines.core)
        }
    }
}

mavenPublishing {
    // Signing needs the key the release workflow holds; a local publication
    // goes unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
}
