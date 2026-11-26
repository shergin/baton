plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

// The base: its host and the lens `scripts/check-bases.sh` generated for it.
kotlin {
    jvm()
    jvmToolchain(21)
    compilerOptions {
        allWarningsAsErrors.set(true)
    }
    sourceSets {
        jvmMain {
            kotlin.srcDir(layout.buildDirectory.dir("baton"))
            dependencies {
                api("com.shergin.baton:baton")
            }
        }
    }
}
