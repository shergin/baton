import java.util.Properties

plugins {
    `kotlin-dsl`
}

/**
 * The release the plugin is versioned with and the compiler bundle it
 * downloads: `kotlin/release.properties`, which the release commit stamps.
 */
val release: Properties = Properties().also { properties ->
    rootDir.resolve("../release.properties").inputStream().use(properties::load)
}

group = "com.shergin.baton"
version = release.getProperty("version")

// The plugin runs under the adopter's Gradle, on a JDK 17 or later, whatever
// JDK builds it.
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
}

gradlePlugin {
    plugins {
        create("baton") {
            id = "com.shergin.baton"
            implementationClass = "baton.gradle.BatonPlugin"
            displayName = "Baton"
            description = "Runs batonc generate over a module's hosts with every input and output declared, and fetches the release's compiler."
        }
    }
}

// The release's version and the bundle's checksum, as a resource the plugin
// reads at run time to know which bundle to fetch.
tasks.processResources {
    val version = release.getProperty("version")
    val bundleSha256 = release.getProperty("bundleSha256")
    inputs.property("version", version)
    inputs.property("bundleSha256", bundleSha256)
    filesMatching("baton/gradle/release.properties") {
        expand("version" to version, "bundleSha256" to bundleSha256)
    }
}

dependencies {
    testImplementation(embeddedKotlin("test-junit5"))
    testImplementation(gradleTestKit())
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}
