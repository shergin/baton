plugins {
    alias(libs.plugins.kotlin.multiplatform)
}

// The dependent: its host, the lenses and the operation
// `scripts/check-bases.sh` generated for it over the base's fragments file,
// and the test that reads one response through both modules' lenses.
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
                api(project(":shared"))
                api("com.shergin.baton:baton")
            }
        }
        jvmTest.dependencies {
            implementation(kotlin("test"))
            implementation("com.shergin.baton:baton-testing")
            implementation(libs.coroutines.test)
        }
    }
}

tasks.named<Test>("jvmTest") {
    systemProperty("baton.spec", rootDir.resolve("../../../spec").canonicalPath)
}
