plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
}

// The Android app over the shared screens (`samples/shared`, where the
// documents are and the code is generated): one activity, the list and then
// the detail, for a phone. The Android Gradle plugin compiles its Kotlin.
android {
    namespace = "baton.sample.android"
    // Compose UI 1.12 is compiled against Android 17's API and asks the same
    // of what depends on it.
    compileSdk = 37
    defaultConfig {
        applicationId = "baton.sample.android"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(project(":samples:shared"))
    implementation(libs.activity.compose)
}
