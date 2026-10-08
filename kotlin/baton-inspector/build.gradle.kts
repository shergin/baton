plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
}

// A view over an environment's store for a debug pane, and its export in the
// dump format `spec/` freezes: a module of its own, so a release build need
// not link it. It reads the store through the runtime's contract with
// generated code, as Swift's `BatonInspector` reads it through
// `@_spi(Generated)`, and never writes.
kotlin {
    jvm()
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
