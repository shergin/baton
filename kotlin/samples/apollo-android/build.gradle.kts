plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.apollo)
}

/** The repository's root, which holds `spec/`. */
val repository: File = rootDir.parentFile

// The Apollo Kotlin twin of `samples/android`: the same two screens over
// Apollo Kotlin and its normalized cache, configured as their documentation
// says. The Gradle plugin compiles the documents of `src/main/graphql`
// against the Rick and Morty schema; the cache's compiler plugin reads the
// `@typePolicy` keys and the `@fieldPolicy` of `extra.graphqls`, adds
// `__typename` and the key fields to every selection set, and generates the
// `cache` builder extension.
apollo {
    service("rickandmorty") {
        packageName.set("baton.sample.apollo.graphql")
        srcDir("src/main/graphql")
        schemaFiles.from(repository.resolve("spec/rickandmorty/schema.graphql"), file("extra.graphqls"))
        plugin("com.apollographql.cache:normalized-cache-apollo-compiler-plugin:${libs.versions.apollo.cache.get()}") {
            argument("com.apollographql.cache.packageName", packageName.get())
        }
    }
}

android {
    namespace = "baton.sample.apollo"
    // Compose UI 1.12 is compiled against Android 17's API and asks the same
    // of what depends on it.
    compileSdk = 37
    defaultConfig {
        applicationId = "baton.sample.apollo"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
    // The release build is what `benchmarks/macro` measures: signed with the
    // debug key, not minified, not debuggable, as the Baton sample's is.
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.apollo.runtime)
    implementation(libs.apollo.normalized.cache)
    implementation(libs.apollo.normalized.cache.sqlite)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    // The fixed server a measured launch fetches from, and the trace sections.
    implementation(project(":benchmarks:macro:server"))
}
