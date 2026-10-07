plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
}

kotlin {
    jvm()
    sourceSets {
        // The runtime is the one module that uses its own contract with
        // generated code everywhere; generated files opt in per file.
        all { languageSettings.optIn("baton.Generated") }
        commonMain.dependencies {
            // The runtime depends on the standard library, kotlinx-coroutines
            // and the Compose runtime, and nothing else; the image's engine
            // and the transports are each target's actuals.
            implementation(libs.coroutines.core)
            implementation(compose.runtime)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
        }
    }
}
