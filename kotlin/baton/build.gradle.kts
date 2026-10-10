import baton.gradle.BatonGenerate
import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.compose)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.android.multiplatform.library)
    alias(libs.plugins.maven.publish)
    id("com.shergin.baton")
}

/** The repository's root, which holds `spec/`. */
val repository: File = rootDir.parentFile

// The specification's sources, generated as the Kotlin target writes them,
// are the test source set's lenses and plans: the harness runs the
// manifest's cases through the code an app would compile. The compiler runs
// from the repository's root, so an output is named `spec_sources_<Name>.baton.kt`.
val generateSpecKotlin = tasks.register<BatonGenerate>("generateSpecKotlin") {
    description = "Generates the Kotlin of spec/sources with batonc."
    workingDirectory.set(repository)
    configuration.set(repository.resolve("spec/tests/baton.json"))
    hosts.from(fileTree(repository.resolve("spec/sources")) { include("*.graphql") })
}

// The device tests' one operation, `spec/sources/Fixture.graphql`, generated
// as the specification's sources are: the ingest benchmark and the image's
// tests on Android run through the plan an app would compile, and need none
// of the converters the other sources name.
val generateBenchmarkKotlin = tasks.register<BatonGenerate>("generateBenchmarkKotlin") {
    description = "Generates the Kotlin of spec/sources/Fixture.graphql with batonc."
    workingDirectory.set(repository)
    configuration.set(repository.resolve("spec/tests/baton.json"))
    hosts.from(repository.resolve("spec/sources/Fixture.graphql"))
}

// Relay's own store tests, harvested into `spec/relay/`, read through the
// Kotlin generated from Relay's test schema with the configuration the relay
// manifest names, as the Swift target `BatonRelayTests` reads them;
// `spec/relay/README.md` says what the harvest kept. An output is named
// `spec_relay_sources_<Name>.graphql.baton.kt`.
val generateRelayKotlin = tasks.register<BatonGenerate>("generateRelayKotlin") {
    description = "Generates the Kotlin of spec/relay/sources with batonc."
    workingDirectory.set(repository)
    configuration.set(repository.resolve("spec/relay/baton.json"))
    hosts.from(fileTree(repository.resolve("spec/relay/sources")) { include("*.graphql") })
}

// The documents an app writes against the server of fate's GraphQL template,
// the host `FateDocuments.kt` beside the fate tests, compiled against the
// schema that server exports under `spec/fate/` with the configuration beside
// the host, as the Swift target `BatonFateTests` compiles its own.
val generateFateKotlin = tasks.register<BatonGenerate>("generateFateKotlin") {
    description = "Generates the Kotlin of the fate documents with batonc."
    configuration.set(layout.projectDirectory.file("src/jvmTest/kotlin/baton/fate/baton.json"))
    hosts.from(layout.projectDirectory.file("src/jvmTest/kotlin/baton/fate/FateDocuments.kt"))
}

kotlin {
    jvm()
    // The JDK the artifacts are compiled with, on the JVM and on Android: the
    // floor `docs/decisions/kotlin-floors.md` records, pinned so a build on
    // another JDK writes the same class files as the release.
    jvmToolchain(21)
    android {
        namespace = "baton"
        compileSdk = 36
        // The lowest the dependencies allow: the Compose runtime and the
        // AndroidX SQLite driver both start at Android 6.
        minSdk = 23
        // The common tests run on the host too, against Android's API.
        withHostTest {}
        // The ingest benchmark and the image's tests on the system's SQLite
        // run on a device or an emulator: `connectedAndroidDeviceTest`.
        withDeviceTest {
            instrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        }
    }
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    applyDefaultHierarchyTemplate {
        common {
            // What the JVM and Android both run: `java.net`, `java.io` and
            // `java.util.concurrent`, which the two platforms share.
            group("jvmShared") {
                withJvm()
                withCompilations { it.platformType == KotlinPlatformType.androidJvm }
            }
        }
    }
    sourceSets {
        // The runtime is the one module that uses its own contract with
        // generated code everywhere; generated files opt in per file.
        all { languageSettings.optIn("baton.Generated") }
        commonMain.dependencies {
            // The runtime depends on the standard library, kotlinx-coroutines,
            // the Compose runtime and the AndroidX SQLite driver API, and
            // nothing else; the image's engine and the transports are each
            // target's actuals. Generated code names Compose's `Stable`, so
            // the Compose runtime is part of the runtime's API. The driver API
            // is interfaces alone: the image is written against it, and each
            // target supplies a driver.
            implementation(libs.coroutines.core)
            api(libs.compose.runtime)
            implementation(libs.sqlite)
        }
        jvmMain.dependencies {
            // The JVM has no SQLite of its own: the image's engine on this
            // target alone is the bundled one, a native library inside the
            // artifact.
            implementation(libs.sqlite.bundled)
        }
        androidMain.dependencies {
            // The system's SQLite, through the framework's `SQLiteDatabase`.
            implementation(libs.sqlite.framework)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.coroutines.test)
        }
        getByName("androidDeviceTest") {
            kotlin.srcDir(generateBenchmarkKotlin.flatMap { it.outputDirectory })
            // The ingest benchmark, which `benchmarks/android` runs in a
            // process that is not debuggable; here it runs in the device
            // test's, which is.
            kotlin.srcDir(rootDir.resolve("benchmarks/android/src/androidTest/kotlin"))
            // The Fixture response, read as a resource.
            resources.srcDir(repository.resolve("spec/rickandmorty"))
            resources.include("characters-page-1.json")
            dependencies {
                implementation(kotlin("test"))
                implementation(libs.coroutines.test)
                implementation(libs.androidx.test.runner)
                implementation(libs.androidx.test.junit)
            }
        }
        jvmTest {
            kotlin.srcDir(generateSpecKotlin.flatMap { it.outputDirectory })
            kotlin.srcDir(generateRelayKotlin.flatMap { it.outputDirectory })
            kotlin.srcDir(generateFateKotlin.flatMap { it.outputDirectory })
            dependencies {
                // The harness walks a `reads` row over a generated lens by its
                // properties' Kotlin names.
                implementation(kotlin("reflect"))
                // The scripts run through the scripted transport an app's tests use.
                implementation(project(":baton-testing"))
                // The exchange of `docs/recipes/exchange.md` is proven here, over the specification's operations.
                implementation(project(":samples:exchange"))
                // The inspector is held in a composition over the specification's operations.
                implementation(project(":baton-inspector"))
                // The composables are tested in a composition, on the desktop's renderer, its main dispatcher the event thread.
                implementation(libs.compose.ui.test.junit4)
                implementation(compose.desktop.currentOs)
                implementation(libs.coroutines.swing)
            }
        }
    }
}

// The registry numbers types by name for the whole process, one schema family
// per process, and the test compilation holds three schemas that give one
// name to different types: Relay's test schema and fate's both declare a
// `User`. So each harness runs in a JVM of its own, from the one compilation:
// the specification's cases and scripts in `jvmTest`, Relay's in
// `jvmRelayTest` and fate's in `jvmFateTest`, by the package each lives in.
val jvmTest = tasks.named<Test>("jvmTest") {
    filter {
        excludeTestsMatching("baton.relay.*")
        excludeTestsMatching("baton.fate.*")
    }
}

/** A test task over the JVM test compilation that runs one package of it, in a process of its own. */
fun harness(name: String, packageName: String, what: String) = tasks.register<Test>(name) {
    description = "Runs $what through the Kotlin test compilation, in a JVM of its own."
    group = "verification"
    testClassesDirs = files(jvmTest.map { it.testClassesDirs })
    classpath = files(jvmTest.map { it.classpath })
    useJUnit()
    filter { includeTestsMatching("$packageName.*") }
}

val jvmRelayTest = harness("jvmRelayTest", "baton.relay", "the cases and scripts of spec/relay")
val jvmFateTest = harness("jvmFateTest", "baton.fate", "the responses recorded under spec/fate")

tasks.named("check") { dependsOn(jvmRelayTest, jvmFateTest) }

// The runtime has no Compose resources. The Compose plugin, applied for the
// desktop renderer the JVM tests compose on, would copy the device tests'
// none into assets through a task the Android library plugin leaves
// unconfigured.
tasks.matching { it.name == "copyAndroidDeviceTestComposeResourcesToAndroidAssets" }.configureEach { enabled = false }

mavenPublishing {
    // Signing needs the key the release workflow holds; a local publication
    // goes unsigned.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
}
