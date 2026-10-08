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
}

rootProject.name = "baton-kotlin"

include(":baton")
include(":goldens")
include(":baton-testing")
include(":baton-inspector")
include(":samples:shared")
include(":samples:desktop")
include(":samples:android")
include(":samples:github")
