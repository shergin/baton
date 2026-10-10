plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.multiplatform.library)
}

// The exchange of `docs/recipes/exchange.md`: a wrapper over the transport's
// one verb an app copies, compiled here so the GitHub sample sends through it
// and the runtime's tests prove it. Common Kotlin over the runtime and
// coroutines alone, so the JVM and Android compile the same file.
kotlin {
    jvm()
    android {
        namespace = "baton.exchange"
        compileSdk = 36
        minSdk = 23
    }
    sourceSets {
        commonMain.dependencies {
            api(project(":baton"))
            implementation(libs.coroutines.core)
        }
    }
}
