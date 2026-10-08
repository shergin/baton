package baton.gradle

import java.io.File
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import org.gradle.api.GradleException

/** The bundle's `info.json` as `scripts/bundle-compiler.sh` writes it. */
internal val bundleInfo = """
    {
      "schemaVersion": "1.0",
      "artifacts": {
        "batonc": {
          "version": "0.12.0",
          "type": "executable",
          "variants": [
            { "path": "batonc-macos/bin/batonc", "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"] },
            { "path": "batonc-linux-x86_64/bin/batonc", "supportedTriples": ["x86_64-unknown-linux-gnu"] },
            { "path": "batonc-linux-aarch64/bin/batonc", "supportedTriples": ["aarch64-unknown-linux-gnu"] }
          ]
        }
      }
    }
""".trimIndent()

class HostTest {
    @Test
    fun an_arm_mac_is_arm64_apple_macosx() {
        assertEquals("arm64-apple-macosx", Host.triple("Mac OS X", "aarch64"))
    }

    @Test
    fun an_intel_mac_is_x86_64_apple_macosx() {
        assertEquals("x86_64-apple-macosx", Host.triple("Mac OS X", "x86_64"))
    }

    @Test
    fun an_arm_linux_is_aarch64_unknown_linux_gnu() {
        assertEquals("aarch64-unknown-linux-gnu", Host.triple("Linux", "aarch64"))
    }

    @Test
    fun an_amd64_linux_is_x86_64_unknown_linux_gnu() {
        assertEquals("x86_64-unknown-linux-gnu", Host.triple("Linux", "amd64"))
    }

    @Test
    fun windows_has_no_triple_and_the_message_names_baton_compiler() {
        val error = assertFailsWith<GradleException> { Host.triple("Windows 11", "amd64") }
        assertContains(error.message.orEmpty(), "BATON_COMPILER")
    }
}

class BundleTest {
    @Test
    fun the_variant_listing_a_triple_gives_its_path() {
        assertEquals("batonc-macos/bin/batonc", Bundle.variant(bundleInfo, "arm64-apple-macosx"))
        assertEquals("batonc-macos/bin/batonc", Bundle.variant(bundleInfo, "x86_64-apple-macosx"))
        assertEquals("batonc-linux-x86_64/bin/batonc", Bundle.variant(bundleInfo, "x86_64-unknown-linux-gnu"))
        assertEquals("batonc-linux-aarch64/bin/batonc", Bundle.variant(bundleInfo, "aarch64-unknown-linux-gnu"))
    }

    @Test
    fun a_triple_no_variant_lists_fails_naming_the_listed_triples() {
        val error = assertFailsWith<GradleException> { Bundle.variant(bundleInfo, "x86_64-pc-windows-msvc") }
        val message = error.message.orEmpty()
        assertContains(message, "x86_64-pc-windows-msvc")
        for (triple in listOf("arm64-apple-macosx", "x86_64-apple-macosx", "x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu")) {
            assertContains(message, triple)
        }
    }
}

class ConfigurationTest {
    private val directory = File("/project/app")

    @Test
    fun the_schema_and_each_extension_resolve_against_the_configuration_directory() {
        val text = """{"schema": "schema.graphql", "schemaExtensions": ["extensions", "local/client.graphql"], "kotlin": {"package": "app"}}"""
        assertEquals(
            listOf(
                directory.resolve("schema.graphql"),
                directory.resolve("extensions"),
                directory.resolve("local/client.graphql"),
            ),
            Configuration.files(text, directory),
        )
    }

    @Test
    fun a_configuration_without_extensions_yields_the_schema_alone() {
        val text = """{"schema": "../schema.graphql", "kotlin": {"package": "app"}}"""
        assertEquals(listOf(directory.resolve("../schema.graphql")), Configuration.files(text, directory))
    }

    @Test
    fun a_configuration_naming_neither_yields_nothing() {
        assertTrue(Configuration.files("""{"kotlin": {"package": "app"}}""", directory).isEmpty())
    }
}
