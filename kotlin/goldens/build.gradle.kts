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

// What the goldens compile against, the runtime and what it depends on, as
// one path: `scripts/hostile-name-sweep-kotlin.py` compiles its probes with
// `kotlinc` against it.
tasks.register("printCompileClasspath") {
    description = "Prints the classpath the goldens compile against."
    val classpath = kotlin.jvm().compilations["main"].compileDependencyFiles
    dependsOn(classpath)
    doLast {
        println(classpath.asPath)
    }
}
