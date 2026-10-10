import baton.gradle.BatonGenerate

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
    id("com.shergin.baton")
}

// What an app's build does: the compiler reads the hosts' documents and
// writes their lenses and operations beside the sources it compiles.
val generateBaton = tasks.named<BatonGenerate>("generateBaton") {
    hosts.from(fileTree("src/jvmMain/kotlin") { include("**/*.kt") })
}

kotlin {
    jvm()
    sourceSets {
        jvmMain {
            kotlin.srcDir(generateBaton.flatMap { it.outputDirectory })
            dependencies {
                implementation(project(":baton"))
                // The exchange of `docs/recipes/exchange.md`, which the app sends through.
                implementation(project(":samples:exchange"))
                implementation(compose.desktop.currentOs)
                implementation(libs.compose.foundation)
                implementation(libs.compose.material3)
                // The environment commits on the main dispatcher, the desktop's event thread.
                implementation(libs.coroutines.swing)
            }
        }
        jvmTest {
            dependencies {
                implementation(kotlin("test"))
                // The screens run over the scripted transport an app's tests use.
                implementation(project(":baton-testing"))
                implementation(libs.compose.ui.test.junit4)
            }
        }
    }
}

compose.desktop {
    application {
        mainClass = "baton.github.MainKt"
    }
}
