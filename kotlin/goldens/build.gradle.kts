plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

// The Kotlin emitter's goldens, compiled against the runtime: a golden that
// does not compile is a fault of the emitter. The sources are the compiler's
// goldens themselves, beside the converters the goldens' configuration names.
kotlin {
    jvm()
    sourceSets {
        jvmMain {
            kotlin.srcDir("../../compiler/src/tests/goldens-kotlin")
            dependencies {
                implementation(project(":baton"))
            }
        }
    }
}
