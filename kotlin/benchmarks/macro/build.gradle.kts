plugins {
    alias(libs.plugins.android.test)
}

// Baton's Android sample and its Apollo Kotlin twin end to end on a device:
// a Macrobenchmark test module that drives both apps' release builds,
// installed beside it, through UiAutomator. Its own build type, `benchmark`,
// matches the apps' `release`; the test APK is debuggable, the apps are not.
android {
    namespace = "baton.macro"
    compileSdk = 36
    defaultConfig {
        minSdk = 29
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildTypes {
        create("benchmark") {
            isDebuggable = true
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
        }
    }
    targetProjectPath = ":samples:android"
    experimentalProperties["android.experimental.self-instrumenting"] = true
}

androidComponents {
    beforeVariants(selector().all()) { it.enable = it.buildType == "benchmark" }
}

dependencies {
    // The section names and the launch extra, the apps' own.
    implementation(project(":benchmarks:macro:server"))
    implementation(libs.benchmark.macro.junit4)
    implementation(libs.uiautomator)
    implementation(libs.androidx.test.junit)
    implementation(libs.androidx.test.runner)
}
