// Two modules of one app, the second spreading a fragment the first
// declares: `shared` is the base, `screens` its dependent. A build of its
// own over the checkout's runtime, which the included build substitutes for
// `com.shergin.baton` artifacts; the generated sources are not the Gradle
// plugin's, which passes no bases yet, but `scripts/check-bases.sh`'s, which
// runs the compiler for each module in turn, the base first, and writes them
// under each module's `build/baton/`.
pluginManagement {
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
    versionCatalogs {
        create("libs") {
            from(files("../../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "baton-bases"

includeBuild("../..")

include(":shared")
include(":screens")
