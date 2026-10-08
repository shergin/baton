plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.maven.publish)
}

// The transports an app's tests run the runtime over: scripted, recorded and
// silent. They are transports like any other, and nothing behind them can
// tell.
kotlin {
    jvm()
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
