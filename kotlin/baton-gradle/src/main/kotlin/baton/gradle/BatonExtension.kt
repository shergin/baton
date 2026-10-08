package baton.gradle

import org.gradle.api.file.RegularFileProperty

/** What `baton {}` configures: the compiler the project's tasks run. */
abstract class BatonExtension {
    /**
     * The `batonc` binary. By convention what the `BATON_COMPILER` Gradle
     * property or environment variable names, a binary or a bundle directory
     * holding an `info.json`, else the bundle of the release the plugin is
     * versioned with, fetched once into the Gradle user home.
     */
    abstract val compiler: RegularFileProperty
}
