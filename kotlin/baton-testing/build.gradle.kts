plugins {
    alias(libs.plugins.kotlin.multiplatform)
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
