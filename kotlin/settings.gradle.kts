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
include(":samples:desktop")
include(":samples:github")
