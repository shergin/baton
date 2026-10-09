import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.multiplatform.library)
    alias(libs.plugins.maven.publish)
}

// The edge over OkHttp: an HTTP transport and a WebSocket client for an app
// that has an OkHttp client, and for Android, whose platform has no
// WebSocket client of its own. The runtime stays on the platform; this
// module is what depends on OkHttp (docs/decisions/one-runtime-module.md).
// The protocols are the runtime's: the response is read as the built-in
// HTTP transport reads it, and `graphql-transport-ws` is spoken by the
// runtime's socket transport over the client this module supplies.
kotlin {
    jvm()
    android {
        namespace = "baton.okhttp"
        // OkHttp 5.5 is compiled against Android 17's API and asks the same
        // of what depends on it.
        compileSdk = 37
        minSdk = 23
        withHostTest {}
        // The transports' tests run on a device against the server doubles
        // of `baton-testing`: `connectedAndroidDeviceTest`.
        withDeviceTest {
            instrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        }
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
        getByName("jvmSharedMain").dependencies {
            api(libs.okhttp)
        }
        jvmTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
            implementation(project(":baton-testing"))
        }
        getByName("androidDeviceTest").dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
            implementation(project(":baton-testing"))
            implementation(libs.androidx.test.runner)
            implementation(libs.androidx.test.junit)
        }
    }
}

mavenPublishing {
    // Signing needs the key the release workflow holds; a local publication
    // goes unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
}
