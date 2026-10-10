pluginManagement {
    // The Gradle plugin, built from the checkout and applied to the modules
    // that generate code, as an adopter applies it from Maven Central.
    includeBuild("baton-gradle")
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "baton-kotlin"

include(":baton")
include(":goldens")
include(":baton-testing")
include(":baton-okhttp")
include(":baton-inspector")
include(":samples:shared")
include(":samples:desktop")
include(":samples:android")
include(":samples:exchange")
include(":samples:github")
include(":samples:apollo-android")
include(":benchmarks:android")
include(":benchmarks:apollo-comparison")
include(":benchmarks:apollo-comparison:android")
include(":benchmarks:macro")
include(":benchmarks:macro:server")
