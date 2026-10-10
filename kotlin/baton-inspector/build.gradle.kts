plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.maven.publish)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.android.multiplatform.library)
}

// A view over an environment's store for a debug pane, and its export in the
// dump format `spec/` freezes: a module of its own, so a release build need
// not link it. It reads the store through the runtime's contract with
// generated code, as Swift's `BatonInspector` reads it through
// `@_spi(Generated)`, and never writes.
kotlin {
    jvm()
    // The JDK the artifacts are compiled with, as `docs/decisions/kotlin-floors.md` records.
    jvmToolchain(21)
    android {
        namespace = "baton.inspector"
        // Compose UI 1.12 is compiled against Android 17's API and asks the
        // same of what depends on it.
        compileSdk = 37
        minSdk = 23
    }
    sourceSets {
        all { languageSettings.optIn("baton.Generated") }
        commonMain.dependencies {
            api(project(":baton"))
            implementation(libs.compose.runtime)
            implementation(libs.compose.foundation)
            implementation(libs.compose.material3)
        }
        jvmTest.dependencies {
            implementation(kotlin("test"))
            implementation(project(":baton-testing"))
            implementation(libs.compose.ui.test.junit4)
            implementation(compose.desktop.currentOs)
            implementation(libs.coroutines.swing)
        }
    }
}

mavenPublishing {
    // Signing needs the key the release workflow holds; a local publication
    // goes unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
}
