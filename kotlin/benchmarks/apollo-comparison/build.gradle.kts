import baton.gradle.BatonGenerate
import org.jetbrains.kotlin.gradle.tasks.AbstractKotlinCompile

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.multiplatform.library)
    alias(libs.plugins.apollo)
    id("com.shergin.baton")
}

/** The repository's root, which holds `spec/` and the Swift comparison. */
val repository: File = rootDir.parentFile

/** The Fixture response Baton reads: the operation's own text, 686,254 bytes. */
val batonFixture: File = repository.resolve("spec/rickandmorty/characters-page-1.json")

/** The same data recorded for Apollo's query text, `__typename` on every object, 849,101 bytes. */
val apolloFixture: File = repository.resolve("benchmarks/apollo-comparison/fixture-apollo.json")

// Baton's side of the operation, generated as an app's build generates it,
// with the configuration the runtime's ingest benchmark uses, from the
// repository's root so the output is named as the runtime's is.
val generateBaton = tasks.named<BatonGenerate>("generateBaton") {
    description = "Generates the Kotlin of spec/sources/Fixture.graphql with batonc."
    workingDirectory.set(repository)
    configuration.set(repository.resolve("spec/tests/baton.json"))
    hosts.from(repository.resolve("spec/sources/Fixture.graphql"))
}

// Apollo's side, configured as its documentation says: the Gradle plugin
// compiles Apollo's copy of the operation, the same query, against the Rick
// and Morty schema, and the normalized cache's compiler plugin reads the
// `@typePolicy` keys of `extra.graphqls`, adds `__typename` and the key
// fields to every selection set, and generates the `cache` builder
// extension.
apollo {
    service("rickandmorty") {
        packageName.set("baton.comparison.apollo")
        srcDir(repository.resolve("benchmarks/apollo-comparison/operations"))
        schemaFiles.from(repository.resolve("spec/rickandmorty/schema.graphql"), file("extra.graphqls"))
        plugin("com.apollographql.cache:normalized-cache-apollo-compiler-plugin:${libs.versions.apollo.cache.get()}") {
            argument("com.apollographql.cache.packageName", packageName.get())
        }
    }
}

kotlin {
    jvm()
    android {
        namespace = "baton.comparison"
        compileSdk = 36
        minSdk = 23
    }
    sourceSets {
        all { languageSettings.optIn("baton.Generated") }
        commonMain {
            kotlin.srcDir(generateBaton.flatMap { it.outputDirectory })
            dependencies {
                implementation(project(":baton"))
                implementation(libs.apollo.runtime)
                implementation(libs.apollo.normalized.cache)
            }
        }
        jvmMain.dependencies {
            implementation(libs.coroutines.core)
        }
    }
}

// The harness times Baton's ingest, commit and availability check apart,
// which the runtime keeps internal, as its own ingest benchmark does: each
// compilation of this module is a friend of what it compiles against, as a
// test compilation is of its main one.
tasks.withType<AbstractKotlinCompile<*>>().configureEach {
    friendPaths.from(libraries)
}

// `gradle :benchmarks:apollo-comparison:runComparison`: the side-by-side
// bench on the JVM the build runs on.
tasks.register<JavaExec>("runComparison") {
    description = "Runs Baton and Apollo Kotlin side by side on the Fixture response, on the JVM."
    val main = kotlin.jvm().compilations.getByName("main")
    classpath(main.output.allOutputs, main.runtimeDependencyFiles)
    mainClass.set("baton.comparison.MainKt")
    args(batonFixture.path, apolloFixture.path)
}
