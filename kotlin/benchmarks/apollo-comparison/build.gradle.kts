import org.jetbrains.kotlin.gradle.tasks.AbstractKotlinCompile

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.multiplatform.library)
    alias(libs.plugins.apollo)
}

/** The repository's root, which holds `spec/`, `compiler/` and the Swift comparison. */
val repository: File = rootDir.parentFile

/** The Fixture response Baton reads: the operation's own text, 686,254 bytes. */
val batonFixture: File = repository.resolve("spec/rickandmorty/characters-page-1.json")

/** The same data recorded for Apollo's query text, `__typename` on every object, 849,101 bytes. */
val apolloFixture: File = repository.resolve("benchmarks/apollo-comparison/fixture-apollo.json")

/**
 * The compiler: the path the `BATON_COMPILER` Gradle property or environment
 * variable names, else the checkout's release build, else its debug build,
 * as the runtime's build finds it.
 */
fun batonCompiler(): File {
    val named = providers.gradleProperty("BATON_COMPILER").orNull
        ?: providers.environmentVariable("BATON_COMPILER").orNull
    if (named != null && named !in setOf("local", "release")) {
        val file = File(named)
        if (!file.isFile) throw GradleException("BATON_COMPILER names $named, which is not a file; point it at a built batonc")
        return file
    }
    return listOf("release", "debug")
        .map { repository.resolve("compiler/target/$it/batonc") }
        .firstOrNull { it.isFile }
        ?: throw GradleException("no batonc to generate the comparison's code with: build it with `cargo build` in compiler/, or set BATON_COMPILER to its path")
}

/** Where batonc writes Baton's side: the plan and lenses of `spec/sources/Fixture.graphql`. */
val generatedBaton: Provider<Directory> = layout.buildDirectory.dir("generated/baton")

// Baton's side of the operation, generated as an app's build generates it,
// with the configuration the runtime's ingest benchmark uses.
val generateBaton = tasks.register<Exec>("generateBaton") {
    description = "Generates the Kotlin of spec/sources/Fixture.graphql with batonc."
    val source = repository.resolve("spec/sources/Fixture.graphql")
    inputs.file(source)
    inputs.files(
        repository.resolve("spec/tests/baton.json"),
        repository.resolve("spec/tests/schema.graphql"),
        repository.resolve("spec/tests/extensions.graphql"),
    )
    inputs.file(providers.provider { batonCompiler() })
    outputs.dir(generatedBaton)
    workingDir = repository
    doFirst {
        commandLine(
            batonCompiler().path, "generate", "--language", "kotlin", "--config", "spec/tests/baton.json",
            "--out", generatedBaton.get().asFile.path, source.relativeTo(repository).path,
        )
    }
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
            kotlin.srcDir(generateBaton)
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
