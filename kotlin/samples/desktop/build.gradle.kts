plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
}

// The desktop app over the shared screens (`samples/shared`, where the
// documents are and the code is generated): its window, its menu and its
// screenshots.
kotlin {
    jvm()
    sourceSets {
        jvmMain {
            dependencies {
                implementation(project(":samples:shared"))
                implementation(compose.desktop.currentOs)
                // The environment commits on the main dispatcher, the desktop's event thread.
                implementation(libs.coroutines.swing)
            }
        }
    }
}

compose.desktop {
    application {
        mainClass = "baton.sample.MainKt"
    }
}

// The screens drawn to PNG files without a window, for the README and for a
// machine with no screen; see `Screenshot.kt`.
tasks.register<JavaExec>("screenshot") {
    description = "Renders the sample's screens to build/screenshots over the live API."
    group = "application"
    val main = kotlin.jvm().compilations.getByName("main")
    dependsOn(main.compileTaskProvider)
    mainClass.set("baton.sample.ScreenshotKt")
    classpath = main.output.allOutputs + main.runtimeDependencyFiles!!
    args(layout.buildDirectory.dir("screenshots").get().asFile.path)
}
